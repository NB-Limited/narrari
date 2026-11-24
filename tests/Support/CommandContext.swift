import Foundation
import NarrariKit
import Synchronization
import Testing

extension Command.Context {
    // Every store in the test's own folder, so no command reaches the owner's data.
    @MainActor
    static func throwaway(
        in folder: TemporaryFolder, settings: SettingsStore, history: HistoryStore? = nil, meetings: MeetingStore? = nil,
        announced: Announcements = Announcements()
    ) -> Command.Context {
        Command.Context(
            settings: settings, models: ModelStore(root: folder.url),
            history: history ?? HistoryStore(root: folder.url.appending(path: "History")),
            meetings: meetings ?? MeetingStore(root: folder.url.appending(path: "Meetings")) { _ in Issue.record("nothing is trashed") },
            apps: AppDirectory(), dataFolder: folder.url, dictionary: DictionaryStore(root: folder.url), prompts: PromptStore(root: folder.url),
            modes: ModeStore(root: folder.url),
            templates: SummaryTemplateFolder(url: folder.url.appending(path: "Templates"), builtIns: SummaryTemplateFolder.bundled),
            voices: VoiceMemory(folder: folder.url), announce: announced.record
        )
    }
}

// The keys a command tells a running Narrari about, in order.
final class Announcements: Sendable {
    private let keys = Mutex<[String]>([])

    var all: [String] { keys.withLock { $0 } }

    func record(_ key: String) {
        keys.withLock { $0.append(key) }
    }
}
