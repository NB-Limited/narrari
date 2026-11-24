import NarrariKit
import SwiftUI

// The settings pages under three heads: what both sides share, then dictation, then meetings.
enum SettingsGroup: CaseIterable, Identifiable {
    case narrari
    case dictation
    case meetings

    var id: Self { self }

    var title: String {
        switch self {
        case .narrari: "Narrari"
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .narrari: [.general, .shortcuts, .speech, .dictionary, .history, .permissions]
        case .dictation: [.recorder, .cleanup, .prompts, .modes]
        case .meetings: [.recording, .summaries, .people]
        }
    }
}

enum SettingsSection: Hashable {
    case general
    case shortcuts
    case speech
    case dictionary
    case history
    case permissions
    case recorder
    case cleanup
    case prompts
    case modes
    case recording
    case summaries
    case people

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .speech: "Speech"
        case .dictionary: "Dictionary"
        case .history: "History"
        case .permissions: "Permissions"
        case .recorder: "Recorder"
        case .cleanup: "Clean-up"
        case .prompts: "Prompts"
        case .modes: "Modes"
        case .recording: "Recording"
        case .summaries: "Summaries"
        case .people: "People"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .speech: "waveform"
        case .dictionary: "character.book.closed"
        case .history: "clock.arrow.circlepath"
        case .permissions: "hand.raised"
        case .recorder: "capsule"
        case .cleanup: "text.badge.checkmark"
        case .prompts: "text.quote"
        case .modes: "rectangle.stack"
        case .recording: "record.circle"
        case .summaries: "doc.text"
        case .people: "person.2"
        }
    }

    @ViewBuilder func page(_ models: SettingsModels) -> some View {
        switch self {
        case .general: GeneralPage(model: models.general)
        case .shortcuts: ShortcutsPage(model: models.shortcuts)
        case .speech: SpeechPage(model: models.speech, meetingModels: models.meetingModels)
        case .dictionary: DictionaryPage(model: models.dictionary)
        case .history: HistoryPage(model: models.history)
        case .permissions: PermissionsPage(permissions: models.permissions)
        case .recorder: RecorderPage(model: models.recorder)
        case .cleanup: CleanupPage(model: models.cleanup)
        case .prompts: PromptsPage(model: models.prompts)
        case .modes: ModesPage(model: models.modes)
        case .recording: RecordingPage(model: models.recording, looks: models.looks)
        case .summaries: SummariesPage(model: models.summaries)
        case .people: PeoplePage(model: models.people)
        }
    }
}
