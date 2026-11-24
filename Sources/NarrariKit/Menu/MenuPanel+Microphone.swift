import Foundation

// The microphone the next dictation records from, chosen in the panel as in Settings.
extension MenuPanel {
    public var microphoneOptions: [MicrophoneOption] { microphones.options }

    public var hasMicrophoneChoice: Bool {
        microphones.devices.count > 1 || microphones.isChosenMissing
    }

    public var microphoneValue: String {
        guard hasMicrophoneChoice else { return microphones.devices.first?.name ?? "None connected" }
        return microphoneOptions.first(where: \.isChosen)?.title ?? "Automatic"
    }
}
