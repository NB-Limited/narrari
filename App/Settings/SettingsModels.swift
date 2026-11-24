import NarrariKit

// One model per settings page, made once when the window first opens so a page keeps its state between visits.
@MainActor
struct SettingsModels {
    let general: GeneralPageModel
    let shortcuts: ShortcutsPageModel
    let speech: SpeechPageModel
    let recorder: RecorderPageModel
    let cleanup: CleanupPageModel
    let prompts: PromptsPageModel
    let dictionary: DictionaryPageModel
    let modes: ModesPageModel
    let history: HistoryPageModel
    let recording: RecordingPageModel
    let summaries: SummariesPageModel
    let people: PeoplePageModel
    let looks: PillLookModel
    let meetingModels: MeetingModels
    let permissions: Permissions
}
