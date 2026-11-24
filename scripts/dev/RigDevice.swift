import CoreAudio
import Darwin
import Foundation
import Synchronization

struct RigDevice {
    static let loopbackUID = "BlackHole16ch_UID"
    // A second silent virtual input, for a microphone that hears nothing.
    static let silentUID = "MSLoopbackDriverDevice_UID"

    let id: AudioObjectID
    let uid: String

    init?(uid: String) {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(Self.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        id = device
        self.uid = uid
    }

    var rate: Double {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    var isRunningSomewhere: Bool {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    var isDefault: Bool {
        [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
            .contains { selector in
                var address = Self.address(selector)
                var device = AudioObjectID(kAudioObjectUnknown)
                var size = UInt32(MemoryLayout<AudioObjectID>.size)
                return AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &device) == noErr && device == id
            }
    }

    func set(rate: Double) async throws {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { throw RigError.rateRefused(rate) }
        for _ in 0..<100 where self.rate != rate { try await Task.sleep(for: .milliseconds(20)) }
        guard self.rate == rate else { throw RigError.rateRefused(rate) }
    }

    func aggregatesOfItselfAlone() -> [Self] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var parts = Self.address(kAudioAggregateDevicePropertyActiveSubDeviceList)
            var partsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &parts, 0, nil, &partsSize) == noErr, partsSize > 0 else { return nil }
            var active = [AudioObjectID](repeating: 0, count: Int(partsSize) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(device, &parts, 0, nil, &partsSize, &active) == noErr, active == [id],
                  let uid = Self.string(kAudioDevicePropertyDeviceUID, of: device)
            else { return nil }
            return Self(uid: uid)
        }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
}

enum RigError: Error, CustomStringConvertible {
    case refused(String)
    // The scenario needs a device this Mac lacks or another app is using; its row says so and does not fail.
    case notRun(String)
    case rateRefused(Double)
    case player(String)

    var description: String {
        switch self {
        case .refused(let reason): "refused: \(reason)"
        case .notRun(let reason): "not run: \(reason)"
        case .rateRefused(let rate): "the loopback device would not run at \(Int(rate)) Hz"
        case .player(let reason): "player: \(reason)"
        }
    }
}

// Asking would put a dialog on the owner's screen, so the rig only reads whether access is already given.
enum RigAccess {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32

    static func isGranted(_ service: String) -> Bool {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(framework, "TCCAccessPreflight")
        else { return false }
        return unsafeBitCast(symbol, to: Preflight.self)(service as CFString, nil) == 0
    }

    static func check(_ loopback: RigDevice) throws {
        guard isGranted("kTCCServiceMicrophone") else { throw RigError.refused("microphone access is not given to the app running this") }
        guard isGranted("kTCCServiceAudioCapture") else {
            throw RigError.refused("system audio recording is not given to the app running this")
        }
        guard !loopback.isDefault else { throw RigError.refused("the loopback device is a default device, so the owner's sound would reach it") }
        guard !loopback.isRunningSomewhere else { throw RigError.refused("another app is using the loopback device") }
    }
}

final class RigPlayer: @unchecked Sendable {
    private let device: RigDevice
    private let channels: Int
    private let signal: @Sendable (Double) -> Float
    private let start: Double
    private let rateBits: Atomic<UInt64>
    private let lastCall = Atomic<UInt64>(0)
    private let stalled = Atomic<UInt64>(0)
    private var proc: AudioDeviceIOProcID?
    private lazy var rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        rateBits.store(device.rate.bitPattern, ordering: .relaxed)
    }

    init(device: RigDevice, channels: Int, start: Double, signal: @escaping @Sendable (Double) -> Float) {
        self.device = device
        self.channels = channels
        self.start = start
        self.signal = signal
        rateBits = Atomic(device.rate.bitPattern)
    }

    func play() throws {
        var address = RigDevice.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(device.id, &address, .main, rateListener)
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { [self] _, _, _, output, time in
            fill(UnsafeMutableAudioBufferListPointer(output), at: time.pointee)
        }
        guard status == noErr, let proc, AudioDeviceStart(device.id, proc) == noErr else { throw RigError.player("the device did not start") }
        self.proc = proc
    }

    var stalledSeconds: Double { Double(stalled.load(ordering: .relaxed)) / 1e9 }

    func stop() {
        guard let proc else { return }
        AudioDeviceStop(device.id, proc)
        AudioDeviceDestroyIOProcID(device.id, proc)
        self.proc = nil
    }

    // A call later than one buffer's time plus 10 ms is the device pausing; what is past the buffer's time counts.
    private func note(_ period: UInt64, isPlaying: Bool) {
        let now = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let previous = lastCall.exchange(now, ordering: .relaxed)
        guard previous > 0, isPlaying, now - previous > period + 10_000_000 else { return }
        stalled.add(now - previous - period, ordering: .relaxed)
    }

    private func fill(_ buffers: UnsafeMutableAudioBufferListPointer, at time: AudioTimeStamp) {
        let rate = Double(bitPattern: rateBits.load(ordering: .relaxed))
        let first = AudioConvertHostTimeToNanos(time.mHostTime)
        let begin = Double(first) / 1e9 - start
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let width = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (4 * max(width, 1))
            if buffer.mData == buffers.first?.mData { note(UInt64(Double(frames) / rate * 1e9), isPlaying: begin > 0) }
            for frame in 0..<frames {
                let value = signal(begin + Double(frame) / rate)
                for channel in 0..<width { data[frame * width + channel] = channel < channels ? value : 0 }
            }
        }
    }
}

func hostSeconds() -> Double {
    Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) / 1e9
}
