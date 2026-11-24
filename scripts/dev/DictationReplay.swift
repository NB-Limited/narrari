import Foundation
import NarrariKit

// Replays the owner's own dictations through clean-up. Its files and its output hold counts, times and short ids only,
// never a word of a dictation, an app name or a prompt name of the owner's own.

actor ReplyLog {
    private(set) var heard: [String] = []
    private(set) var replies: [String?] = []
    private(set) var seconds: [Double] = []

    func start(_ transcript: String) -> Int {
        heard.append(transcript)
        replies.append(nil)
        seconds.append(.nan)
        return replies.count - 1
    }

    func finish(_ call: Int, reply: String?, seconds elapsed: Double) {
        replies[call] = reply
        seconds[call] = elapsed
    }
}

// Passes through to the local model and keeps every reply with its time, so a turned-down reply can still be scored.
struct LoggingEngine: CleanupEngine {
    let engine: LocalModelEngine
    let log = ReplyLog()
    var name: String { engine.name }
    var runsInApp: Bool { engine.runsInApp }
    var state: ModelState { get async { await engine.state } }
    func load() async throws { try await engine.load() }
    func unload() async { await engine.unload() }
    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String {
        let call = await log.start(transcript)
        let start = ContinuousClock.now
        do {
            let reply = try await engine.rewrite(transcript, instruction: instruction, growth: growth)
            await log.finish(call, reply: reply, seconds: seconds(since: start))
            return reply
        } catch {
            await log.finish(call, reply: nil, seconds: seconds(since: start))
            throw error
        }
    }
}

// For measuring only: these fillers never ship as a rule.
struct ReplayMeasure: Codable {
    static let fillers: Set<String> = ["uh", "um", "er", "uhm"]

    let heardWords: Int
    let replyWords: Int
    let contentKept: Double
    let added: Double
    let fillersIn: Int
    let fillersLeft: Int
    // Share of the heard words that are not fillers missing from the reply's words that are not fillers.
    let lost: Double

    init(heard: String, reply: String) {
        let fit = ReplyFit(transcript: heard, reply: reply)
        func fillers(_ text: String) -> Int {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { Self.fillers.contains(String($0)) }.count
        }
        heardWords = fit.transcriptWords
        replyWords = fit.replyWords
        contentKept = fit.contentKept
        added = fit.added
        fillersIn = fillers(heard)
        fillersLeft = fillers(reply)
        let said = heardWords - fillersIn
        lost = said > 0 ? Double(said - (replyWords - fillersLeft)) / Double(said) : 0
    }
}

struct ReplayRow: Codable {
    let id: String
    var variant: String
    let prompt: String
    let measure: ReplayMeasure
    let seconds: Double
    let status: String
    let chunks: Int
    let cleaned: Int
    let skipped: Int
    let reasons: [String]
    let sameAsWhole: Bool?
}

struct ChunkRow: Codable {
    let id: String
    let variant: String
    let index: Int
    // Against the model's reply, also one the service turned down; the heard words when there was no reply.
    let measure: ReplayMeasure
    let replied: Bool
    let seconds: Double
    let status: String
    let reason: String?
}

func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

func quantile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
}

func loadAverage() -> Double {
    var load = [0.0, 0.0, 0.0]
    return getloadavg(&load, 3) > 0 ? load[0] : .nan
}

func dictationReplay(_ experiment: String, history: String, out: String, model: String?) async throws {
    if experiment == "text" {
        try await dictationReplayText(history: history, out: out, model: model)
    } else if experiment == "ahead" {
        try await dictationReplayAhead(history: history, out: out)
    } else {
        try await dictationReplayPieces(history: history, out: out)
    }
}

func replayEntries(_ folder: String) async throws -> [HistoryEntry] {
    try await HistoryStore(root: URL(filePath: folder)).entries().entries
        .filter { $0.isFinished && $0.file == nil && SentenceChunks.wordCount(Substring($0.rawText)) > 0 }
        .sorted { $0.startedAt < $1.startedAt }
}

func writeLines(_ rows: [some Encodable], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var data = Data()
    for row in rows { data += try encoder.encode(row) + Data("\n".utf8) }
    try data.write(to: url)
}

func readLines<Row: Decodable>(_ type: Row.Type, from url: URL) throws -> [Row] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
}

struct ReplayCleaner {
    let engine: LoggingEngine
    let service: CleanupService
    let pipeline: TextPipeline
    let spellings: [String]
    var calls = 0

    // A prompt that rewrites is cleaned whole by the app too, so its pipeline row reuses the whole one.
    mutating func replay(_ entry: HistoryEntry, prompt: Prompt) async -> ([ReplayRow], [ChunkRow]) {
        let (whole, result) = await whole(entry, prompt: prompt)
        guard prompt.capsReplyLength else {
            var row = whole
            row.variant = "pipeline"
            return ([whole, row], [])
        }
        let (row, chunks) = await piped(entry, prompt: prompt, whole: result)
        return ([whole, row], chunks)
    }

    mutating func whole(_ entry: HistoryEntry, prompt: Prompt) async -> (ReplayRow, CleanupResult) {
        let start = ContinuousClock.now
        let result = await service.clean(entry.rawText, with: prompt, spellings: spellings)
        let elapsed = seconds(since: start)
        calls += 1
        let row = ReplayRow(
            id: shortID(entry.id), variant: "whole", prompt: Self.label(prompt), measure: ReplayMeasure(heard: entry.rawText, reply: result.text),
            seconds: elapsed, status: result.status.rawValue, chunks: 1, cleaned: result.status == .cleaned ? 1 : 0,
            skipped: result.status == .cleaned ? 0 : 1, reasons: result.reason.map { [$0.rawValue] } ?? [], sameAsWhole: nil
        )
        return (row, result)
    }

    // Through the app's own path; a chunk counts as turned down when the model gave no reply or one the service's guard refuses.
    mutating func piped(_ entry: HistoryEntry, prompt: Prompt, whole: CleanupResult) async -> (ReplayRow, [ChunkRow]) {
        let first = await engine.log.replies.count
        let start = ContinuousClock.now
        let result = await pipeline.run(heard: entry.rawText, prompt: prompt).cleanup
        let elapsed = seconds(since: start)
        let heard = await engine.log.heard[first...]
        let replies = await engine.log.replies[first...]
        let times = await engine.log.seconds[first...]
        calls += heard.count
        let chunkRows = zip(heard.indices, heard).map { index, piece in
            let reply = replies[index]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCleaned = reply.map { reply in
                !reply.isEmpty && ReplyFit(transcript: piece, reply: reply).suits(prompt) && !SpokenLanguage.differs(reply, from: piece)
            } ?? false
            return ChunkRow(
                id: shortID(entry.id), variant: "pipeline", index: index - first, measure: ReplayMeasure(heard: piece, reply: reply ?? piece),
                replied: reply != nil, seconds: times[index], status: isCleaned ? "cleaned" : "skipped", reason: nil
            )
        }
        let cleaned = chunkRows.filter { $0.status == "cleaned" }.count
        let row = ReplayRow(
            id: shortID(entry.id), variant: "pipeline", prompt: Self.label(prompt), measure: ReplayMeasure(heard: entry.rawText, reply: result.text),
            seconds: elapsed, status: result.status.rawValue, chunks: chunkRows.count, cleaned: cleaned, skipped: chunkRows.count - cleaned,
            reasons: result.reason.map { [$0.rawValue] } ?? [], sameAsWhole: chunkRows.count == 1 ? result.text == whole.text : nil
        )
        return (row, chunkRows)
    }

    // Only a built-in prompt's id is shown; a prompt of the owner's own may carry a name of theirs.
    static func label(_ prompt: Prompt) -> String {
        PromptStore.builtIn.contains { $0.id == prompt.id } ? prompt.id : "own"
    }
}

// Experiment 1: every finished dictation cleaned whole, and through the app's pipeline, which cleans a prompt that keeps
// the speaker's words in runs of sentences.
func dictationReplayText(history: String, out: String, model: String?) async throws {
    let folder = URL(filePath: out)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let entries = try await replayEntries(history)
    let prompts = (try? PromptStore.shared.all()) ?? PromptStore.builtIn
    let spellings = try DictionaryStore.shared.load().words
    let local = LocalModelEngine(model: ModelReference(model ?? SettingsStore.shared.value(CleanupSettings.localModel)), store: .shared)
    try await local.load()
    let engine = LoggingEngine(engine: local)
    let service = CleanupService(engine: engine, settings: .shared)
    let pipeline = TextPipeline(cleanup: service, prompts: .shared, dictionary: .shared, settings: .shared)
    _ = await service.clean("um so this is just a warm up sentence", with: .tidy)
    print(String(
        format: "%d dictations, %d dictionary words, load average %.1f, footprint %.0f MB",
        entries.count, spellings.count, loadAverage(), memoryMegabytes().footprint
    ))
    var cleaner = ReplayCleaner(engine: engine, service: service, pipeline: pipeline, spellings: spellings)
    var rows: [ReplayRow] = []
    var chunkRows: [ChunkRow] = []
    var nextReport = 100
    for entry in entries {
        let prompt = entry.prompt.flatMap { id in prompts.first { $0.id == id } } ?? .tidy
        let (entryRows, entryChunks) = await cleaner.replay(entry, prompt: prompt)
        rows += entryRows
        chunkRows += entryChunks
        if cleaner.calls >= nextReport {
            print(String(format: "%d clean-ups, footprint %.0f MB, load average %.1f", cleaner.calls, memoryMegabytes().footprint, loadAverage()))
            nextReport += 100
        }
    }
    print(String(format: "%d clean-ups, footprint %.0f MB at the end", cleaner.calls, memoryMegabytes().footprint))
    await local.unload()
    try writeLines(rows, to: folder.appending(path: "text-rows.jsonl"))
    try writeLines(chunkRows, to: folder.appending(path: "text-chunks.jsonl"))
    printTextSummary(rows: rows, chunks: chunkRows)
}

func printTextSummary(rows: [ReplayRow], chunks: [ChunkRow]) {
    let buckets: [(String, ClosedRange<Int>)] = [("1-25", 1...25), ("26-75", 26...75), ("76-150", 76...150), ("151+", 151...Int.max)]
    print("\nvariant | words | n | p50 s | p90 s | total s | kept<0.9 | kept<0.8 | lost>10% | skipped whole | chunks skipped | fillers in | left")
    for variant in ["whole", "pipeline"] {
        for (label, range) in buckets + [("all", 1...Int.max)] {
            let set = rows.filter { $0.variant == variant && range.contains($0.measure.heardWords) }
            let times = set.map(\.seconds)
            print(String(
                format: "%@ | %@ | %d | %.2f | %.2f | %.0f | %d | %d | %d | %d | %d | %d | %d", variant, label, set.count,
                quantile(times, 0.5), quantile(times, 0.9), times.reduce(0, +), set.filter { $0.measure.contentKept < 0.9 }.count,
                set.filter { $0.measure.contentKept < 0.8 }.count, set.filter { $0.measure.lost > 0.1 }.count,
                set.filter { $0.status == "skipped" }.count, set.reduce(0) { $0 + ($1.chunks > 1 ? $1.skipped : 0) },
                set.reduce(0) { $0 + $1.measure.fillersIn }, set.reduce(0) { $0 + $1.measure.fillersLeft }
            ))
        }
    }
    let single = rows.filter { $0.variant == "pipeline" && $0.sameAsWhole != nil }
    print("\none-chunk dictations cleaned again: \(single.count), text differs from whole: \(single.filter { $0.sameAsWhole == false }.count)")
    let reasons = Dictionary(grouping: rows.flatMap { row in row.reasons.map { "\(row.variant) \($0)" } }, by: { $0 }).mapValues(\.count)
    print("reasons: " + reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    printChunkGuard(chunks, variant: "pipeline")
}

// Lossy: the reply lost more than a tenth of the chunk's words beyond fillers. Each threshold is on contentKept alone.
func printChunkGuard(_ all: [ChunkRow], variant: String) {
    let chunks = all.filter(\.replied)
    let kept = chunks.map(\.measure.contentKept)
    let added = chunks.map(\.measure.added)
    print(String(
        format: "\n%@: %d chunks; contentKept p1 %.2f p5 %.2f p10 %.2f p50 %.2f; added p50 %.2f p90 %.2f p95 %.2f p99 %.2f", variant, chunks.count,
        quantile(kept, 0.01), quantile(kept, 0.05), quantile(kept, 0.1), quantile(kept, 0.5),
        quantile(added, 0.5), quantile(added, 0.9), quantile(added, 0.95), quantile(added, 0.99)
    ))
    let lossy = chunks.filter { $0.measure.lost > 0.1 }
    let sound = chunks.filter { $0.measure.lost <= 0.1 }
    let turnedDown = chunks.filter { $0.status != "cleaned" }.count
    print("no reply \(all.count - chunks.count), lossy \(lossy.count), sound \(sound.count), today's guard turned down \(turnedDown)")
    print("kept below | lossy caught | sound turned down")
    for threshold in [0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9] {
        print(String(
            format: "%.2f | %d | %d", threshold,
            lossy.filter { $0.measure.contentKept < threshold }.count, sound.filter { $0.measure.contentKept < threshold }.count
        ))
    }
    let fit = linearFit(chunks.filter { $0.status == "cleaned" && !$0.seconds.isNaN }.map { (Double($0.measure.heardWords), $0.seconds) })
    print(String(format: "clean-up seconds per chunk = %.3f + %.4f x words", fit.intercept, fit.slope))
}

func linearFit(_ points: [(Double, Double)]) -> (intercept: Double, slope: Double) {
    let count = Double(points.count)
    guard count > 1 else { return (.nan, .nan) }
    let meanX = points.map(\.0).reduce(0, +) / count
    let meanY = points.map(\.1).reduce(0, +) / count
    let spread = points.map { ($0.0 - meanX) * ($0.0 - meanX) }.reduce(0, +)
    let slope = spread > 0 ? points.map { ($0.0 - meanX) * ($0.1 - meanY) }.reduce(0, +) / spread : 0
    return (meanY - slope * meanX, slope)
}
