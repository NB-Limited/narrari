import CoreAudio
import Foundation
import Observation

public struct Microphone: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MicrophoneOption: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let isChosen: Bool
    public let isInUse: Bool
}

// Where the list of input devices comes from, and the call when it changes.
@MainActor
public protocol MicrophoneSource: AnyObject {
    // `automatic` is the ID of the microphone a dictation uses when none is chosen.
    func read(prefersBuiltIn: Bool) -> (devices: [Microphone], automatic: String?)
    func watch(_ onChange: @escaping @MainActor () -> Void)
    func unwatch()
}

// The input devices of this Mac and the chosen one, kept current while a page or the menu panel shows them.
@MainActor
@Observable
public final class Microphones {
    public private(set) var devices: [Microphone] = []
    // The microphone a dictation uses when none is chosen or the chosen one is not connected.
    public private(set) var automatic: Microphone?
    // Empty for Automatic.
    public private(set) var chosenID: String

    public static let missingTitle = "Chosen microphone, not connected"

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let source: any MicrophoneSource

    public init(settings: SettingsStore, source: any MicrophoneSource) {
        self.settings = settings
        self.source = source
        chosenID = settings.value(DictationSettings.microphoneUID)
    }

    public func start() {
        chosenID = settings.value(DictationSettings.microphoneUID)
        refresh()
        source.watch { [weak self] in self?.refresh() }
    }

    public func stop() {
        source.unwatch()
    }

    public func refresh() {
        let reading = source.read(prefersBuiltIn: settings.value(DictationSettings.prefersBuiltInOverBluetooth))
        devices = reading.devices
        automatic = reading.automatic.flatMap { id in reading.devices.first { $0.id == id } }
    }

    public func choose(_ id: String) {
        chosenID = id
        settings.set(id, for: DictationSettings.microphoneUID)
    }

    public var isChosenMissing: Bool {
        !chosenID.isEmpty && !devices.contains { $0.id == chosenID }
    }

    // Automatic, the connected inputs, and a chosen one that is not connected. The stored choice carries the check;
    // when that is Automatic or not connected, the device used instead is in use.
    public var options: [MicrophoneOption] {
        let inUse = chosenID.isEmpty || isChosenMissing ? automatic?.id : nil
        var options = [MicrophoneOption(id: "", title: "Automatic", isChosen: chosenID.isEmpty, isInUse: false)]
        options += devices.map { MicrophoneOption(id: $0.id, title: $0.name, isChosen: $0.id == chosenID, isInUse: $0.id == inUse) }
        if isChosenMissing {
            options.append(MicrophoneOption(id: chosenID, title: Self.missingTitle, isChosen: true, isInUse: false))
        }
        return options
    }
}

public final class SystemMicrophones: MicrophoneSource {
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var onChange: (@MainActor () -> Void)?

    public init() {}

    public func read(prefersBuiltIn: Bool) -> (devices: [Microphone], automatic: String?) {
        let devices = AudioDevices.inputDevices().compactMap { device -> Microphone? in
            guard let uid = AudioDevices.uid(of: device) else { return nil }
            return Microphone(id: uid, name: AudioDevices.name(of: device) ?? uid)
        }
        let pick = MicrophonePick.current(chosenUID: "", prefersBuiltIn: prefersBuiltIn)
        return (devices, pick.flatMap { AudioDevices.uid(of: $0.device) })
    }

    public func watch(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioDevices.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            if status == noErr {
                listeners.append((address, block))
            } else {
                Log.failure("microphone-list-listener")
            }
        }
    }

    public func unwatch() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listeners = []
        onChange = nil
    }
}
