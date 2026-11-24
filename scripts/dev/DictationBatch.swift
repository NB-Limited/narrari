import Foundation
import NarrariKit

// Every call the app's service makes on the batching path, in order, so each piece's reply and the path it took are known.
actor BatchCallLog {
    enum Call {
        // Nil replies: the batch threw and its pieces were cleaned one by one.
        case together(count: Int, replies: [String?]?)
        case alone(String?)
    }

    private(set) var calls: [Call] = []

    func add(_ call: Call) { calls.append(call) }
}

// Passes through to the local model, batching as the app's engine does, and keeps every call.
struct BatchLoggingEngine: BatchCleanupEngine {
    let engine: LocalModelEngine
    let log = BatchCallLog()
    var name: String { engine.name }
    var runsInApp: Bool { engine.runsInApp }
    var state: ModelState { get async { await engine.state } }
    func load() async throws { try await engine.load() }
    func unload() async { await engine.unload() }

    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String {
        do {
            let reply = try await engine.rewrite(transcript, instruction: instruction, growth: growth)
            await log.add(.alone(reply))
            return reply
        } catch {
            await log.add(.alone(nil))
            throw error
        }
    }

    func rewrite(together transcripts: [String], instruction: String, growth: ReplyGrowth) async throws -> [String?] {
        do {
            let replies = try await engine.rewrite(together: transcripts, instruction: instruction, growth: growth)
            await log.add(.together(count: transcripts.count, replies: replies))
            return replies
        } catch {
            await log.add(.together(count: transcripts.count, replies: nil))
            throw error
        }
    }
}

enum PiecePath: String, Codable {
    case batch, redo, fallback, alone
}

struct BatchPieceRow: Codable {
    let id: String
    let index: Int
    let words: Int
    let dictationWords: Int
    let path: PiecePath
    // Nil when the one by one side gave no reply.
    let sameAsOneByOne: Bool?
    let oneByOnePasses: Bool
    let batchPasses: Bool
}

// A batch's pieces in order; a piece it did not finish takes the next call alone, as the service makes it.
func piecePaths(_ calls: [BatchCallLog.Call]) -> [(reply: String?, path: PiecePath)] {
    var pieces: [(reply: String?, path: PiecePath)] = []
    var index = calls.startIndex
    func nextAlone() -> String? {
        guard index < calls.endIndex, case .alone(let reply) = calls[index] else { return nil }
        index += 1
        return reply
    }
    while index < calls.endIndex {
        let call = calls[index]
        index += 1
        switch call {
        case .alone(let reply):
            pieces.append((reply, .alone))
        case .together(let count, let replies):
            for row in 0 ..< count {
                if let reply = replies?[row] {
                    pieces.append((reply, .batch))
                } else {
                    pieces.append((nextAlone(), replies == nil ? .fallback : .redo))
                }
            }
        }
    }
    return pieces
}

func passes(_ reply: String?, piece: String, prompt: Prompt) -> Bool {
    guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
    return ReplyFit(transcript: piece, reply: text).suits(prompt) && !(prompt.keepsWhatWasSaid && SpokenLanguage.differs(text, from: piece))
}

// Each dictation the app cleans in sentence runs, through the app's pipeline twice: on an engine that cleans the runs one
// by one, then on the app's batching engine. All one by one first, so each pass's peak memory reads on its own.
func dictationReplayBatch(history: String, out: String, model: String?) async throws {
    let folder = URL(filePath: out)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let prompts = (try? PromptStore.shared.all()) ?? PromptStore.builtIn
    func prompt(of entry: HistoryEntry) -> Prompt { entry.prompt.flatMap { id in prompts.first { $0.id == id } } ?? .tidy }
    let entries = try await replayEntries(history).filter { prompt(of: $0).capsReplyLength }
    let local = LocalModelEngine(model: ModelReference(model ?? SettingsStore.shared.value(CleanupSettings.localModel)), store: .shared)
    try await local.load()
    let solo = LoggingEngine(engine: local)
    let batching = BatchLoggingEngine(engine: local)
    let soloPipeline = TextPipeline(cleanup: CleanupService(engine: solo, settings: .shared), prompts: .shared, dictionary: .shared, settings: .shared)
    _ = await CleanupService(engine: solo, settings: .shared).clean("um so this is just a warm up sentence", with: .tidy)
    print(String(format: "%d dictations cleaned in runs, load average %.1f, footprint %.0f MB", entries.count, loadAverage(), memoryMegabytes().footprint))

    var rows: [ReplayRow] = []
    var soloCalls: [(heard: [String], replies: [String?])] = []
    for entry in entries {
        let first = await solo.log.replies.count
        let start = ContinuousClock.now
        let result = await soloPipeline.run(heard: entry.rawText, prompt: prompt(of: entry)).cleanup
        rows.append(replayRow(entry, prompt(of: entry), variant: "one-by-one", result: result, seconds: seconds(since: start)))
        soloCalls.append(await (Array(solo.log.heard[first...]), Array(solo.log.replies[first...])))
    }
    let soloPeak = memoryMegabytes().peak
    print(String(format: "one by one done, load average %.1f, peak footprint %.0f MB", loadAverage(), soloPeak))

    let pieceRows = await replayBatched(entries, soloCalls: soloCalls, rows: &rows, engine: batching, prompt: prompt(of:))
    let batchPeak = memoryMegabytes().peak
    print(String(format: "batched done, load average %.1f, peak footprint %.0f MB", loadAverage(), batchPeak))
    try writeLines(rows, to: folder.appending(path: "batch-rows.jsonl"))
    try writeLines(pieceRows, to: folder.appending(path: "batch-pieces.jsonl"))
    printVariants(rows, ["one-by-one", "batched"])
    printBatchPieces(pieceRows)
    await local.unload()
    print(String(format: "peak footprint: one by one %.0f MB, after batched %.0f MB; %.0f MB after unload", soloPeak, batchPeak, memoryMegabytes().footprint))
}

func replayBatched(
    _ entries: [HistoryEntry], soloCalls: [(heard: [String], replies: [String?])], rows: inout [ReplayRow],
    engine batching: BatchLoggingEngine, prompt: (HistoryEntry) -> Prompt
) async -> [BatchPieceRow] {
    let pipeline = TextPipeline(cleanup: CleanupService(engine: batching, settings: .shared), prompts: .shared, dictionary: .shared, settings: .shared)
    var pieceRows: [BatchPieceRow] = []
    for (entry, soloCall) in zip(entries, soloCalls) {
        let first = await batching.log.calls.count
        let start = ContinuousClock.now
        let result = await pipeline.run(heard: entry.rawText, prompt: prompt(entry)).cleanup
        rows.append(replayRow(entry, prompt(entry), variant: "batched", result: result, seconds: seconds(since: start)))
        let paths = piecePaths(await Array(batching.log.calls[first...]))
        guard paths.count == soloCall.heard.count else {
            print("\(shortID(entry.id)): \(paths.count) batched pieces against \(soloCall.heard.count) one by one, left out")
            continue
        }
        let words = SentenceChunks.wordCount(Substring(entry.rawText))
        pieceRows += soloCall.heard.indices.map { index in
            let piece = soloCall.heard[index]
            return BatchPieceRow(
                id: shortID(entry.id), index: index, words: SentenceChunks.wordCount(Substring(piece)), dictationWords: words,
                path: paths[index].path, sameAsOneByOne: soloCall.replies[index].map { $0 == paths[index].reply },
                oneByOnePasses: passes(soloCall.replies[index], piece: piece, prompt: prompt(entry)),
                batchPasses: passes(paths[index].reply, piece: piece, prompt: prompt(entry))
            )
        }
    }
    return pieceRows
}

func replayRow(_ entry: HistoryEntry, _ prompt: Prompt, variant: String, result: CleanupResult, seconds: Double) -> ReplayRow {
    ReplayRow(
        id: shortID(entry.id), variant: variant, prompt: ReplayCleaner.label(prompt), measure: ReplayMeasure(heard: entry.rawText, reply: result.text),
        seconds: seconds, status: result.status.rawValue, chunks: 0, cleaned: 0, skipped: 0,
        reasons: result.reason.map { [$0.rawValue] } ?? [], sameAsWhole: nil
    )
}

func printBatchPieces(_ pieces: [BatchPieceRow]) {
    let buckets: [(String, ClosedRange<Int>)] = [("1-25", 1...25), ("26-75", 26...75), ("76-150", 76...150), ("151+", 151...Int.max)]
    print("\nwords | pieces | same as one by one | one by one passes | batched passes | batch | redo alone | fallback | alone")
    for (label, range) in buckets + [("all", 1...Int.max)] {
        let set = pieces.filter { range.contains($0.dictationWords) }
        func count(_ path: PiecePath) -> Int { set.filter { $0.path == path }.count }
        print(String(
            format: "%@ | %d | %d of %d | %d | %d | %d | %d | %d | %d", label, set.count, set.filter { $0.sameAsOneByOne == true }.count,
            set.compactMap(\.sameAsOneByOne).count, set.filter(\.oneByOnePasses).count, set.filter(\.batchPasses).count,
            count(.batch), count(.redo), count(.fallback), count(.alone)
        ))
    }
}
