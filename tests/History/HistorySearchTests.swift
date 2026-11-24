import Foundation
import NarrariKit
import Testing

@MainActor
struct HistorySearchTests {
    private let apps = AppDirectory(folders: [])

    private func entry(heard: String = "", shown: String = "", file: String? = nil, app: String = "") -> HistoryEntry {
        let id = UUID()
        var entry = HistoryEntry(
            id: id, startedAt: Date(), app: app, rawText: heard, finalText: shown, audioFile: HistoryEntry.audioFileName(for: id)
        )
        entry.file = file
        return entry
    }

    @Test func text_heard_text_shown_and_file_name_are_searched_ignoring_case_and_accents() {
        let shown = entry(shown: "Café on Thursday.")
        let heard = entry(heard: "um the RÉSUMÉ draft", shown: "The draft.")
        let file = entry(file: "Interview Zoë.m4a")
        let other = entry(shown: "Lunch at noon.")
        let all = [shown, heard, file, other]

        #expect(HistorySearch.entries(all, matching: "cafe", apps: apps) == [shown])
        #expect(HistorySearch.entries(all, matching: "resume", apps: apps) == [heard])
        #expect(HistorySearch.entries(all, matching: "zoe", apps: apps) == [file])
        #expect(HistorySearch.entries(all, matching: "  ", apps: apps) == all)
    }

    // Foundation matches ß, ligatures, a few old letters and stray marks in ways their folded forms don't show, so these are in on purpose.
    private static let pieces = [
        "kalo", "MIREN", "Tuva", "sel", "dofi", "nor", "café", "cafe\u{301}", "CAFÉ", "Straße", "STRASSE", "strasse", "ß", "ẞ", "st", "ss",
        "İkalo", "ikalo", "ı", "ﬁ", "fi", "ﬀ", "ffi", "fx", "Здравей", "ЗДРАВЕЙ", "й", "и\u{306}", "ёлка", "е\u{308}", "ᲀ", "В", "в",
        "Ꭰ", "ꭰ", "Zoë", "zoe", "ZOE\u{308}", "Ångström", "A\u{30A}ngstro\u{308}m", "ŉ", "ǰ", "ΐ", "Σίσυφος", "ς", "ι", "\u{345}",
        "Ԫ\u{319}ɟ", "Ԫɟ", "\u{13}\u{345}", "\r\n", "\u{0}", "-", "."
    ]

    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11
        }
    }

    private static func text(_ random: inout Seeded) -> String {
        (0..<Int.random(in: 0...6, using: &random)).map { _ in pieces.randomElement(using: &random) ?? "" }
            .joined(separator: Bool.random(using: &random) ? " " : "")
    }

    private static func query(from texts: [String], _ random: inout Seeded) -> String {
        let text = Array(texts.randomElement(using: &random) ?? "")
        guard !text.isEmpty else { return pieces.randomElement(using: &random) ?? "" }
        let start = Int.random(in: 0..<text.count, using: &random)
        let part = String(text[start..<Int.random(in: (start + 1)...text.count, using: &random)])
        return switch Int.random(in: 0..<5, using: &random) {
        case 0: part.uppercased()
        case 1: part.lowercased()
        case 2: part.decomposedStringWithCanonicalMapping
        case 3: part.precomposedStringWithCanonicalMapping
        default: part
        }
    }

    // The search as it was before the words were kept between searches: every field of every entry compared.
    private func everyField(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.finalText, entry.rawText, EntryFormat.source(entry, apps: apps)].contains { field in
                field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    @Test func finds_what_comparing_every_field_found_in_awkward_text_before_and_after_entries_change() {
        var random = Seeded(state: 24)
        var entries = Self.pieces.map { entry(shown: $0) } + (0..<160).map { index in
            entry(
                heard: Self.text(&random), shown: Self.text(&random), file: index.isMultiple(of: 3) ? Self.text(&random) : nil,
                app: "com.example.\(Self.text(&random))"
            )
        }
        let fields = entries.flatMap { [$0.finalText, $0.rawText, EntryFormat.source($0, apps: apps)] }
        // Across the end of one field and the start of the next, which no field holds.
        let across = entries.prefix(20).map { String($0.finalText.suffix(2)) + "\u{0}" + String($0.rawText.prefix(2)) }
        var queries = Self.pieces + across
        for _ in 0..<400 { queries.append(Self.query(from: fields, &random)) }

        var search = HistorySearch()
        var mismatches = queries.filter { search.entries(entries, matching: $0, apps: apps) != everyField(entries, $0) }
        for index in stride(from: 0, to: entries.count, by: 7) { entries[index].finalText = Self.text(&random) }
        entries.removeLast(10)
        entries.insert(entry(shown: "Straße ﬁ Здравей"), at: 0)
        mismatches += queries.filter { search.entries(entries, matching: $0, apps: apps) != everyField(entries, $0) }

        #expect(mismatches.isEmpty)
    }
}
