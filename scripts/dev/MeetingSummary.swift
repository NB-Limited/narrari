import Foundation
import NarrariKit

private struct NoDictation: DictationActivity {
    func updates() -> AsyncStream<Bool> {
        AsyncStream { $0.yield(false) }
    }
}

private struct NoKeys: KeyStoring {
    func read(_: String) -> String? { nil }
    func contains(_: String) -> Bool { false }
    func write(_: String, for _: String) {}
    func delete(_: String) {}
}

private struct SummaryScore {
    let languageKept: Bool
    let unknownNames: [String]
    let headingsFound: Int
    let headingsFilled: Int
    let words: Int
    let isSaneLength: Bool

    init(summary: String, template: SummaryTemplate, source: String, transcriptWords: Int) {
        languageKept = SpokenLanguage.likeliest(summary).map { SpokenLanguage.words(byLanguage: [source])[$0] != nil } ?? false
        let known = Set(Self.words(source + " " + template.sections.map { $0.heading + " " + $0.instruction }.joined(separator: " ")))
        unknownNames = Self.capitalisedMidSentence(summary).filter { !known.contains($0.lowercased()) && $0 != "None" }
        let lines = summary.split(whereSeparator: \.isNewline).map(String.init)
        let headings = template.sections.map { $0.heading.lowercased() }
        var found = 0
        var filled = 0
        for heading in headings {
            guard let index = lines.firstIndex(where: { Self.headingText($0) == heading }) else { continue }
            found += 1
            let body = lines[(index + 1)...].prefix { !$0.hasPrefix("#") && !headings.contains(Self.headingText($0)) }
            if body.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { filled += 1 }
        }
        headingsFound = found
        headingsFilled = filled
        words = Self.words(summary).count
        isSaneLength = (40...600).contains(words) && words < transcriptWords
    }

    private static func headingText(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: ").union(.whitespaces)).lowercased()
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // Words that start with a capital where a sentence does not start: the names, places and products a summary uses.
    private static func capitalisedMidSentence(_ text: String) -> [String] {
        var found: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var startsSentence = true
            for token in line.split(separator: " ") {
                let word = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                    .replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "’s", with: "")
                if !startsSentence, let first = word.first, first.isUppercase, word.count > 1 { found.append(word) }
                let end = token.trimmingCharacters(in: CharacterSet(charactersIn: "*_)\"\u{201D}"))
                if !word.isEmpty { startsSentence = end.last.map { ".!?:".contains($0) } ?? false }
            }
        }
        return found
    }
}

// Prints only times and scores, so a run on real meetings shows none of their words; the summaries go to the out folder.
@MainActor
func meetingSummaries(_ scratch: ScratchMeetings, out outPath: String, models: [String]) async throws {
    let templates = SummaryTemplateFolder(url: scratch.data.appending(path: "Templates"), builtIns: SummaryTemplateFolder.bundled)
    print("model | meeting | template | minutes | transcript words | seconds | peak MB | outcome | language kept | unknown names | "
        + "headings found | filled | words | sane length")
    let slot = CleanupEngineSlot(settings: scratch.settings, keychain: NoKeys(), store: scratch.models)
    let engines = CleanupSummaryEngines(slot: slot, settings: scratch.settings, keychain: NoKeys(), store: scratch.models)
    let service = SummaryService(
        templates: templates, engines: engines, dictation: NoDictation(), settings: scratch.settings, clock: ContinuousClock()
    )
    for model in models {
        scratch.settings.set(model, for: CleanupSettings.localModel)
        slot.reload()
        guard let engine = slot.current else { continue }
        let loadStart = ContinuousClock.now
        try await engine.load()
        let name = ModelReference(model).displayName
        print(String(format: "%@ loaded in %.1f s, %.0f MB", name, seconds(since: loadStart), memoryMegabytes().footprint))
        for meeting in try await scratch.store.meetings().meetings.sorted(by: { $0.title < $1.title }) {
            for template in try templates.all() where SummaryTemplateFolder.builtInIDs.contains(template.id) {
                try await summarise(meeting, with: template, by: name, service: service, scratch: scratch, out: URL(filePath: outPath))
            }
        }
        await engine.unload()
    }
}

@MainActor
private func summarise(
    _ meeting: Meeting, with template: SummaryTemplate, by name: String, service: SummaryService, scratch: ScratchMeetings, out: URL
) async throws {
    let segments = try await scratch.store.transcript(of: meeting.id)
    let notes = try await scratch.store.text(.notes, of: meeting.id)
    let source = (meeting.speakers.map(\.name) + meeting.attendees.map(\.name) + [notes] + segments.map(\.text)).joined(separator: "\n")
    let transcriptWords = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
    var chosen = meeting
    chosen.template = template.id
    try await scratch.store.save(chosen)
    try await scratch.store.write("", to: .summary, of: meeting.id)
    let peak = PeakMemory()
    let watcher = Task {
        while !Task.isCancelled {
            await peak.sample()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    var outcome = "written"
    let start = ContinuousClock.now
    do {
        try await service.run(meeting.id, in: scratch.store)
    } catch {
        outcome = "refused: \(error.localizedDescription)"
    }
    let elapsed = seconds(since: start)
    watcher.cancel()
    let summary = try await scratch.store.text(.summary, of: meeting.id)
    let label = "\(meeting.title)-\(template.id)-\(name.replacingOccurrences(of: " ", with: ""))"
    try summary.write(to: out.appending(path: label + ".md"), atomically: true, encoding: .utf8)
    let score = SummaryScore(summary: summary, template: template, source: source, transcriptWords: transcriptWords)
    try score.unknownNames.joined(separator: "\n").write(to: out.appending(path: label + ".names"), atomically: true, encoding: .utf8)
    print(String(
        format: "%@ | %@ | %@ | %.1f | %d | %.1f | %.0f | %@ | %@ | %d | %d/%d | %d | %d | %@",
        name, meeting.title, template.id, Double(meeting.durationMs) / 60000, transcriptWords, elapsed, await peak.megabytes,
        outcome, score.languageKept ? "yes" : "no", score.unknownNames.count, score.headingsFound, template.sections.count,
        score.headingsFilled, score.words, score.isSaneLength ? "yes" : "no"
    ))
}
