import Foundation

// The history page and the narrari command search with this one filter; case and accents are ignored.
public enum HistorySearch {
    @MainActor
    public static func entries(_ entries: [HistoryEntry], matching query: String, apps: AppDirectory) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.finalText, entry.rawText, EntryFormat.source(entry, apps: apps)].contains { field in
                field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
