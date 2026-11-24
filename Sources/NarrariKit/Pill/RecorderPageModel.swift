import Foundation
import Observation

// The Recorder page: what a dictation sounds and looks like while it records.
@MainActor
@Observable
public final class RecorderPageModel {
    public private(set) var canMuteOutput = true
    public var playsSounds: Bool {
        get { settings[DictationSettings.playsSounds] }
        set { settings[DictationSettings.playsSounds] = newValue }
    }
    public var soundSet: SoundSet { settings[DictationSettings.soundSet] }
    public private(set) var playingSound: SoundSet?
    public var mutesOutput: Bool {
        get { settings[DictationSettings.mutesOutput] }
        set { settings[DictationSettings.mutesOutput] = newValue }
    }
    public var showsLiveText: Bool {
        get { settings[DictationSettings.showsLiveText] }
        set { settings[DictationSettings.showsLiveText] = newValue }
    }
    public var pillLook: PillLook {
        get { settings[PillSettings.look] }
        set { settings[PillSettings.look] = newValue }
    }
    public var pillColour: PillColour {
        get { settings[PillSettings.colour] }
        set { settings[PillSettings.colour] = newValue }
    }

    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let canMute: @MainActor () -> Bool
    @ObservationIgnored private let playPreview: @MainActor (SoundSet) async -> Void
    @ObservationIgnored private var previewing: Task<Void, Never>?

    public init(
        settings: SettingsMirror, canMute: @escaping @MainActor () -> Bool, preview: @escaping @MainActor (SoundSet) async -> Void = { _ in }
    ) {
        self.settings = settings
        self.canMute = canMute
        playPreview = preview
    }

    public var muteDetail: String? {
        mutesOutput && !canMuteOutput ? "This output can't be muted." : nil
    }

    public func appear() {
        canMuteOutput = canMute()
    }

    public func chooseSound(_ set: SoundSet) {
        settings[DictationSettings.soundSet] = set
        previewSound(set)
    }

    // A new preview drops what is left of the one before, so quick clicks never pile up.
    public func previewSound(_ set: SoundSet) {
        previewing?.cancel()
        playingSound = set
        previewing = Task { [weak self, playPreview] in
            await playPreview(set)
            guard !Task.isCancelled else { return }
            self?.playingSound = nil
        }
    }
}
