import CoreAudio
import Foundation

// A tap on all sound the Mac plays except Narrari's own, read through a private aggregate device on the output device.
// Muting and capturing differ in the mute flag and in what the reader does. If Narrari dies, the system removes both.
final class SystemAudioTap {
    enum Use {
        case mute
        case capture
    }

    enum Sound: Sendable {
        case allButOwn
        case only(pid_t)
    }

    let aggregate: AudioObjectID
    private let tap: AudioObjectID
    private var reader: AudioDeviceIOProcID?

    init?(_ use: Use, outputUID: String, sound: Sound = .allButOwn) {
        let description = switch sound {
        case .allButOwn: CATapDescription(stereoGlobalTapButExcludeProcesses: Self.process(of: getpid()).map { [$0] } ?? [])
        case .only(let pid): CATapDescription(stereoMixdownOfProcesses: Self.process(of: pid).map { [$0] } ?? [])
        }
        description.muteBehavior = use == .mute ? .muted : .unmuted
        description.isPrivate = true
        description.name = "Narrari"
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            Log.failure("system-tap-create")
            return nil
        }
        // A capture starts at once, so the track's clock runs from the start; auto start would wait for the first sound.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Narrari",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: use == .mute,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate) == noErr else {
            Log.failure("system-tap-aggregate")
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        self.tap = tap
        self.aggregate = aggregate
    }

    // On failure the tap is removed, so the caller only drops it.
    func start(reading block: @escaping AudioDeviceIOBlock) -> Bool {
        guard AudioDeviceCreateIOProcIDWithBlock(&reader, aggregate, nil, block) == noErr,
              AudioDeviceStart(aggregate, reader) == noErr
        else {
            Log.failure("system-tap-start")
            remove()
            return false
        }
        return true
    }

    @discardableResult
    func remove() -> Bool {
        var isRemoved = true
        if let reader {
            _ = AudioDeviceStop(aggregate, reader)
            isRemoved = AudioDeviceDestroyIOProcID(aggregate, reader) == noErr && isRemoved
            self.reader = nil
        }
        isRemoved = AudioHardwareDestroyAggregateDevice(aggregate) == noErr && isRemoved
        isRemoved = AudioHardwareDestroyProcessTap(tap) == noErr && isRemoved
        if !isRemoved { Log.failure("system-tap-remove") }
        return isRemoved
    }

    // Narrari's own is left out of the tap, so its start and stop sounds stay audible and never reach a meeting's track.
    private static func process(of pid: pid_t) -> AudioObjectID? {
        var address = AudioDevices.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process
        )
        return status == noErr && process != kAudioObjectUnknown ? process : nil
    }
}

// The meeting's second track: every sound the Mac plays but Narrari's, from the default output's tap.
public struct SystemAudioCapture: SystemSoundSource {
    private let rig: (outputUID: String, process: pid_t)?

    public init() {
        rig = nil
    }

    // For a test rig: one process's sound alone, on a silent device, so nobody else's sound is heard.
    public init(outputUID: String, onlyProcess process: pid_t) {
        rig = (outputUID, process)
    }

    public func makeEngine(onChange: @escaping @Sendable () -> Void) -> any InputEngine {
        SystemAudioEngine(onChange: onChange, outputUID: rig?.outputUID, sound: rig.map { .only($0.process) } ?? .allButOwn)
    }
}

final class SystemAudioEngine: InputEngine, @unchecked Sendable {
    private static let listening = DispatchQueue(label: "com.nb-limited.narrari.system-sound")

    private let tap: SystemAudioTap?
    // Calls `onChange` when the output device changes rate or format, as a Bluetooth headset does when a call opens its microphone.
    private let input: DeviceInputEngine?
    private let onChange: @Sendable () -> Void
    private var isListening = false
    private lazy var listener: AudioObjectPropertyListenerBlock = { [onChange] _, _ in
        DispatchQueue.main.async { onChange() }
    }

    init(onChange: @escaping @Sendable () -> Void, outputUID: String?, sound: SystemAudioTap.Sound) {
        self.onChange = onChange
        guard let uid = outputUID ?? AudioDevices.defaultOutput().flatMap(AudioDevices.uid(of:)),
              let tap = SystemAudioTap(.capture, outputUID: uid, sound: sound)
        else {
            tap = nil
            input = nil
            return
        }
        let input = DeviceInputEngine(device: tap.aggregate, reading: .last, onChange: onChange)
        guard input.sampleRate != nil else {
            Log.failure("system-tap-no-format")
            tap.remove()
            self.tap = nil
            self.input = nil
            return
        }
        self.tap = tap
        self.input = input
    }

    var sampleRate: Double? { input?.sampleRate }

    func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) throws {
        guard let tap, let input else { throw RecorderError.noInput }
        do {
            try input.start(feeding: feed)
        } catch {
            Log.failure("system-capture-start")
            tap.remove()
            throw error
        }
        listen(true)
    }

    func stop() {
        listen(false)
        input?.stop()
        tap?.remove()
    }

    // A new default output means the tap's device no longer plays the call, so the recorder builds a fresh one.
    private func listen(_ isOn: Bool) {
        guard isOn != isListening else { return }
        var address = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
        let system = AudioObjectID(kAudioObjectSystemObject)
        let status = isOn
            ? AudioObjectAddPropertyListenerBlock(system, &address, Self.listening, listener)
            : AudioObjectRemovePropertyListenerBlock(system, &address, Self.listening, listener)
        if status == noErr { isListening = isOn } else { Log.failure("system-tap-output-listener") }
    }
}
