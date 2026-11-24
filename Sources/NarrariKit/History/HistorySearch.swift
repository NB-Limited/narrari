import Foundation

// The history page and the narrari command search with this one filter; case and accents are ignored. Each dictation's
// words are kept between searches and prepared again only when its text or source changed.
@MainActor
public struct HistorySearch {
    private var held: [UUID: TextSearch.Lines] = [:]

    public init() {}

    public static func entries(_ entries: [HistoryEntry], matching query: String, apps: AppDirectory) -> [HistoryEntry] {
        var search = HistorySearch()
        return search.entries(entries, matching: query, apps: apps)
    }

    public mutating func entries(_ entries: [HistoryEntry], matching query: String, apps: AppDirectory) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        let needle = TextSearch.Needle(query)
        var kept: [UUID: TextSearch.Lines] = .init(minimumCapacity: entries.count)
        let found = entries.filter { entry in
            let fields = [entry.finalText, entry.rawText, EntryFormat.source(entry, apps: apps)]
            let lines = held[entry.id].flatMap { $0.texts == fields ? $0 : nil } ?? TextSearch.Lines(fields)
            kept[entry.id] = lines
            return lines.first(holding: needle) != nil
        }
        held = kept
        return found
    }
}
