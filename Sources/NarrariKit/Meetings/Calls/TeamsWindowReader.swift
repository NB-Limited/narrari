import Foundation

// Teams builds its window tree only in assistive mode. Its people panel groups the call's people under a row
// "In this meeting (3)", apart from those invited who have not joined; each person's row has the name as its first text.
struct TeamsWindowReader: CallWindowReader {
    let apps = ["com.microsoft.teams2", "com.microsoft.teams"]
    let needsAssistiveMode = true
    let unread: StaticString = "teams-window-unread"

    func names(in windows: [WindowElement]) -> [String]? {
        windows.lazy.compactMap { $0.first { $0.starts(with: "In this meeting") } }.first?.rowTexts
    }
}
