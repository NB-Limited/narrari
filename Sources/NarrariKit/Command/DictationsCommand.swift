import Foundation

enum DictationsCommand: RecordCommand {
    private static let previewLength = 60

    static func list(since: Date?, limit: Int?, asJSON: Bool, in context: Command.Context) async throws -> String {
        let entries = Array(try await finished(in: context).filter { entry in since.map { entry.startedAt >= $0 } ?? true }.prefix(limit ?? .max))
        return asJSON ? try json(entries) : rows(entries, apps: context.apps)
    }

    static func search(_ text: String, limit: Int?, in context: Command.Context) async throws -> String {
        let found = HistorySearch.entries(try await finished(in: context), matching: text, apps: context.apps)
        return rows(Array(found.prefix(limit ?? .max)), apps: context.apps)
    }

    // A part belongs to a meeting; a dictation has its text alone.
    static func read(_ id: UUID, part _: MeetingPart?, in context: Command.Context) async throws -> String? {
        guard let entry = try await finished(in: context).first(where: { $0.id == id }) else { return nil }
        let head = "\(RecordKind.started(entry.startedAt)), \(EntryFormat.length(entry)), \(EntryFormat.source(entry, apps: context.apps))"
        return "\(head)\n\n\(text(entry))\n"
    }

    private static func finished(in context: Command.Context) async throws -> [HistoryEntry] {
        try await context.history.entries().entries.filter(\.isFinished)
    }

    // What was pasted, or what was heard when nothing was.
    private static func text(_ entry: HistoryEntry) -> String {
        entry.finalText.isEmpty ? entry.rawText : entry.finalText
    }

    private static func rows(_ entries: [HistoryEntry], apps: AppDirectory) -> String {
        guard !entries.isEmpty else { return "No dictations.\n" }
        return RecordKind.table(
            ["ID", "STARTED", "LENGTH", "FROM", "TEXT"],
            entries.map { entry in
                let text = text(entry)
                let preview = text.count > previewLength ? text.prefix(previewLength) + "..." : text
                return [entry.id.uuidString, RecordKind.started(entry.startedAt), EntryFormat.length(entry), EntryFormat.source(entry, apps: apps), preview]
            }
        )
    }

    // As the history files hold them, one entry per element.
    private static func json(_ entries: [HistoryEntry]) throws -> String {
        let list = Data("[".utf8) + Data(try entries.map { try $0.jsonLine() }.joined(separator: Data(",".utf8))) + Data("]\n".utf8)
        return String(bytes: list, encoding: .utf8) ?? ""
    }
}
