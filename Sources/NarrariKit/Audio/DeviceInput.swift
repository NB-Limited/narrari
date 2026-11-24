import CoreAudio
import Foundation
import Synchronization

// How a device's input reaches its IO proc: one buffer per input stream, each interleaved in its stream's format.
public struct InputLayout: Sendable, Equatable {
    public enum Part: Sendable {
        case all
        // A tap's stream, which an aggregate lists after any input of its sub-device.
        case last
    }

    public enum Sample: Sendable, Equatable {
        case float32
        case int16
        case int32
    }

    public struct Stream: Sendable, Equatable {
        public let channels: Int
        public let sample: Sample

        public init?(_ format: AudioStreamBasicDescription) {
            let flags = format.mFormatFlags
            let channels = Int(format.mChannelsPerFrame)
            guard format.mFormatID == kAudioFormatLinearPCM, channels > 0, flags & kAudioFormatFlagIsBigEndian == 0,
                  flags & kAudioFormatFlagIsNonInterleaved == 0 || channels == 1,
                  format.mBytesPerFrame == format.mChannelsPerFrame * format.mBitsPerChannel / 8
            else { return nil }
            let isFloat = flags & kAudioFormatFlagIsFloat != 0
            let isSigned = flags & kAudioFormatFlagIsSignedInteger != 0
            switch (isFloat, isSigned, format.mBitsPerChannel) {
            case (true, _, 32): sample = .float32
            case (false, true, 16): sample = .int16
            case (false, true, 32): sample = .int32
            default: return nil
            }
            self.channels = channels
        }

        var bytesPerFrame: Int {
            switch sample {
            case .float32, .int32: channels * 4
            case .int16: channels * 2
            }
        }
    }

    public let sampleRate: Double
    public let streams: [Stream]
    let skipped: Int

    public init(sampleRate: Double, streams: [Stream], skipped: Int = 0) {
        self.sampleRate = sampleRate
        self.streams = streams
        self.skipped = skipped
    }

    // The rate is the device's, not its streams': a tap's stream keeps the tap's own rate, though it arrives at the aggregate's.
    public init?(sampleRate: Double, formats: [AudioStreamBasicDescription], reading part: Part = .all) {
        let read = part == .all ? formats[...] : formats.suffix(1)
        var streams: [Stream] = []
        for format in read {
            guard let stream = Stream(format) else { return nil }
            streams.append(stream)
        }
        guard sampleRate > 0, !streams.isEmpty else { return nil }
        self.init(sampleRate: sampleRate, streams: streams, skipped: formats.count - streams.count)
    }

    static func of(_ device: AudioObjectID, reading part: Part = .all) -> InputLayout? {
        let ids = AudioDevices.inputStreams(of: device)
        let formats = ids.compactMap(AudioDevices.virtualFormat(of:))
        guard formats.count == ids.count, let sampleRate = AudioDevices.nominalSampleRate(of: device) else { return nil }
        return InputLayout(sampleRate: sampleRate, formats: formats, reading: part)
    }

    public func frames(in buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
        guard buffers.count == skipped + streams.count else { return nil }
        var frames = Int.max
        for (stream, buffer) in zip(streams, buffers.dropFirst(skipped)) {
            guard Int(buffer.mNumberChannels) == stream.channels else { return nil }
            frames = min(frames, Int(buffer.mDataByteSize) / stream.bytesPerFrame)
        }
        return frames
    }

    // Averages every channel of `count` frames from `offset` into one.
    public func mix(
        _ buffers: UnsafeMutableAudioBufferListPointer, from offset: Int, count: Int, into output: UnsafeMutablePointer<Float>
    ) {
        output.update(repeating: 0, count: count)
        var total = 0
        for (stream, buffer) in zip(streams, buffers.dropFirst(skipped)) {
            total += stream.channels
            guard let data = buffer.mData else { continue }
            switch stream.sample {
            case .float32: Self.add(data.assumingMemoryBound(to: Float.self), stream.channels, offset, count, 1, output)
            case .int16: Self.add(data.assumingMemoryBound(to: Int16.self), stream.channels, offset, count, 1 / 32_768, output)
            case .int32: Self.add(data.assumingMemoryBound(to: Int32.self), stream.channels, offset, count, 1 / 2_147_483_648, output)
            }
        }
        let scale = 1 / Float(max(total, 1))
        for frame in 0..<count { output[frame] *= scale }
    }

    // Mixes every frame to mono, `scratch.count` at a time, and hands each part to `feed` with the buffer's host time.
    func feed(
        _ buffers: UnsafeMutableAudioBufferListPointer, hostTime: UInt64, through scratch: UnsafeMutableBufferPointer<Float>,
        to feed: (UnsafeBufferPointer<Float>, UInt64) -> Void
    ) {
        guard let frames = frames(in: buffers), frames > 0, let mixed = scratch.baseAddress else { return }
        autoreleasepool {
            var offset = 0
            while offset < frames {
                let count = min(scratch.count, frames - offset)
                mix(buffers, from: offset, count: count, into: mixed)
                feed(UnsafeBufferPointer(start: mixed, count: count), hostTime)
                offset += count
            }
        }
    }

    private static func add<Value: PCMValue>(
        _ samples: UnsafePointer<Value>, _ channels: Int, _ offset: Int, _ count: Int, _ scale: Float, _ output: UnsafeMutablePointer<Float>
    ) {
        for frame in 0..<count {
            let first = (offset + frame) * channels
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[first + channel].float }
            output[frame] += sum * scale
        }
    }
}

extension AudioTimeStamp {
    // 0 when the device gave no host time.
    var hostTimeIfValid: UInt64 { mFlags.contains(.hostTimeValid) ? mHostTime : 0 }
}

private protocol PCMValue {
    var float: Float { get }
}

extension Float: PCMValue { fileprivate var float: Float { self } }
extension Int16: PCMValue { fileprivate var float: Float { Float(self) } }
extension Int32: PCMValue { fileprivate var float: Float { Float(self) } }

// `proc` and `feed` change on main only while the device is stopped, so the IO thread reads them unlocked.
final class DeviceInputEngine: InputEngine, @unchecked Sendable {
    private static let listening = DispatchQueue(label: "com.nb-limited.narrari.device-input")
    private static let chunkFrames = 4096

    private let device: AudioObjectID
    private let part: InputLayout.Part
    private let layout: InputLayout?
    private let onChange: @Sendable () -> Void
    // Set once the device stops delivering in `layout`, so the IO proc drops what it can no longer read.
    private let isStale = Atomic<Bool>(false)
    private let isRunning = Atomic<Bool>(false)
    private var proc: AudioDeviceIOProcID?
    private let mixed = UnsafeMutableBufferPointer<Float>.allocate(capacity: chunkFrames)
    private var feed: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?
    private var listened: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }

    init(device: AudioObjectID, reading part: InputLayout.Part = .all, onChange: @escaping @Sendable () -> Void) {
        self.device = device
        self.part = part
        self.onChange = onChange
        layout = InputLayout.of(device, reading: part)
    }

    deinit {
        mixed.deallocate()
    }

    var sampleRate: Double? { layout?.sampleRate }

    func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) throws {
        guard proc == nil, layout != nil else { throw RecorderError.noInput }
        self.feed = feed
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [self] _, input, time, _, _ in
            deliver(input, at: time)
        }
        if status == noErr, let proc {
            status = AudioDeviceStart(device, proc)
            if status != noErr { AudioDeviceDestroyIOProcID(device, proc) }
        }
        guard status == noErr, let proc else {
            Log.count("input-start-status", Int(status))
            throw RecorderError.startFailed
        }
        self.proc = proc
        isRunning.store(true, ordering: .sequentiallyConsistent)
        listen()
        // Catches a change that landed between reading the layout and listening for changes.
        Self.listening.async { [weak self] in self?.check() }
    }

    func stop() {
        guard let proc else { return }
        isRunning.store(false, ordering: .sequentiallyConsistent)
        for (object, address) in listened {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, Self.listening, listener)
        }
        listened = []
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
        self.proc = nil
        feed = nil
    }

    private func deliver(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        guard !isStale.load(ordering: .relaxed), let layout, let feed else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        layout.feed(buffers, hostTime: time.pointee.hostTimeIfValid, through: mixed, to: feed)
    }

    private func listen() {
        var targets = [
            (device, AudioDevices.address(kAudioDevicePropertyDeviceIsAlive)),
            (device, AudioDevices.address(kAudioDevicePropertyNominalSampleRate)),
            (device, AudioDevices.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)),
            (device, AudioDevices.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput))
        ]
        for stream in AudioDevices.inputStreams(of: device) {
            targets.append((stream, AudioDevices.address(kAudioStreamPropertyVirtualFormat)))
        }
        for (object, address) in targets {
            var address = address
            if AudioObjectAddPropertyListenerBlock(object, &address, Self.listening, listener) == noErr {
                listened.append((object, address))
            } else {
                Log.failure("input-format-listener")
            }
        }
    }

    // Runs on the listening queue, never on main, and only hands over to main, so the HAL never waits on main.
    private func check() {
        guard isRunning.load(ordering: .sequentiallyConsistent), !isStale.load(ordering: .relaxed) else { return }
        if AudioDevices.isAlive(device), InputLayout.of(device, reading: part) == layout { return }
        guard !isStale.exchange(true, ordering: .relaxed) else { return }
        DispatchQueue.main.async { [self] in
            if isRunning.load(ordering: .sequentiallyConsistent) { onChange() }
        }
    }
}
