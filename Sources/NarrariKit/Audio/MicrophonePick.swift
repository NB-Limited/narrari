import CoreAudio

// The microphone a dictation records from.
public enum MicrophonePick: Sendable, Equatable {
    case chosen(AudioObjectID)
    case systemDefault(AudioObjectID)
    // Opening a Bluetooth headset's microphone drops its sound to call quality until it closes.
    case builtInOverBluetooth(AudioObjectID)

    public var device: AudioObjectID {
        switch self {
        case .chosen(let device), .systemDefault(let device), .builtInOverBluetooth(let device): device
        }
    }

    // `chosen` is the chosen microphone when it is connected; without it the system default is used.
    public static func resolve(
        chosen: AudioObjectID?, systemDefault: AudioObjectID?,
        inputs: [(device: AudioObjectID, transport: UInt32)], prefersBuiltIn: Bool
    ) -> MicrophonePick? {
        if let chosen { return .chosen(chosen) }
        guard let systemDefault else { return nil }
        let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
        guard prefersBuiltIn,
              let transport = inputs.first(where: { $0.device == systemDefault })?.transport, bluetooth.contains(transport),
              let builtIn = inputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn })
        else { return .systemDefault(systemDefault) }
        return .builtInOverBluetooth(builtIn.device)
    }

    static func current(chosenUID uid: String, prefersBuiltIn: Bool) -> MicrophonePick? {
        var chosen: AudioObjectID?
        if !uid.isEmpty {
            chosen = AudioDevices.device(uid: uid)
            if chosen == nil { Log.event("microphone-fallback-to-default") }
        }
        let inputs = AudioDevices.inputDevices().map { (device: $0, transport: AudioDevices.transport(of: $0)) }
        return resolve(chosen: chosen, systemDefault: AudioDevices.defaultInput(), inputs: inputs, prefersBuiltIn: prefersBuiltIn)
    }
}
