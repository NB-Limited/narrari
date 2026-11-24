import CoreAudio

// How a microphone is connected, in the few kinds that change how it behaves.
public enum MicrophoneTransport: Sendable, Equatable {
    case builtIn
    case usb
    case bluetooth
    case other

    init(_ transport: UInt32) {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        default: self = .other
        }
    }

    public var name: String {
        switch self {
        case .builtIn: "built-in"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .other: "other"
        }
    }

    func log() {
        switch self {
        case .builtIn: Log.event("microphone-transport-built-in")
        case .usb: Log.event("microphone-transport-usb")
        case .bluetooth: Log.event("microphone-transport-bluetooth")
        case .other: Log.event("microphone-transport-other")
        }
    }
}
