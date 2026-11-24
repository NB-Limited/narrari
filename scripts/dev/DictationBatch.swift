import Foundation
import MLX
import MLXLMCommon
import NarrariKit

struct BatchChunkRow: Codable {
    let id: String
    let index: Int
    let words: Int
    let batchSize: Int
    let soloTokens: Int
    let batchTokens: Int
    // The app's own reply and the batch decoder's reply at one row; nil when the app gave no reply.
    let soloSameAsApp: Bool?
    let batchSameAsSolo: Bool
    let firstDifference: Int?
    let appPasses: Bool
    let batchPasses: Bool
}

struct SweepRow: Codable {
    let batchSize: Int
    let batches: Int
    let rows: Int
    let tokens: Int
    let seconds: Double
    let firstStepSeconds: Double
    let peakMegabytes: Double
    let footprintAfter: Double
    let cacheMegabytesAfter: Double
    let sameAsSolo: Int
    let sameAsOtherOrder: Int?
}

struct DecodedRows: Sendable {
    let prompts: [[Int]]
    let caps: [Int]
    let tokens: [[Int]]
    let texts: [String]
    let isCutOff: [Bool]
    let seconds: Double
    let firstStepSeconds: Double
}

// Prompts and kept instructions are read and written only inside the engine's model access, one call at a time.
final class BatchBench: @unchecked Sendable {
    private var kept: [String: KeptInstruction] = [:]
    let parameters = GenerateParameters(temperature: 0)

    func prompt(_ transcript: String, instruction: String, growth: ReplyGrowth, context: ModelContext) async throws -> (KeptInstruction, [Int], Int) {
        let thinkingOff = try context.configuration.reasoningConfig?.promptStrategy.additionalContext(forThinkingEnabled: false)
        func tokens(_ text: String) async throws -> [Int] {
            try await context.processor.prepare(
                input: UserInput(chat: [.system(instruction), .user(text)], additionalContext: thinkingOff)
            ).text.tokens.asArray(Int.self)
        }
        let state: KeptInstruction
        if let known = kept[instruction] {
            state = known
        } else {
            let one = try await tokens("alpha")
            let other = try await tokens("omega")
            state = try KeptInstruction(reading: zip(one, other).prefix { $0 == $1 }.map(\.0), with: context, parameters: parameters)
            kept[instruction] = state
        }
        let cap = growth.tokenLimit(for: context.tokenizer.encode(text: transcript, addSpecialTokens: false).count)
        return (state, try await tokens(transcript), cap)
    }

    func decode(_ calls: [(transcript: String, instruction: String, growth: ReplyGrowth)], context: ModelContext) async throws -> DecodedRows {
        var prepared: [(KeptInstruction, [Int], Int)] = []
        for call in calls { prepared.append(try await prompt(call.transcript, instruction: call.instruction, growth: call.growth, context: context)) }
        let decoder = BatchDecoder(context: context)
        let run = try decoder.run(prepared.map(\.1), caps: prepared.map(\.2), from: prepared[0].0, parameters: parameters)
        return DecodedRows(
            prompts: prepared.map(\.1), caps: prepared.map(\.2), tokens: run.replies.map(\.tokens),
            texts: run.replies.map { context.tokenizer.decode(tokenIds: $0.tokens) }, isCutOff: run.replies.map(\.isCutOff),
            seconds: run.seconds, firstStepSeconds: run.firstStepSeconds
        )
    }

    func run(_ prompts: [[Int]], caps: [Int], instruction: String, context: ModelContext) throws -> BatchRun {
        guard let state = kept[instruction] else { throw BatchDecodeError.instructionNotRead }
        return try BatchDecoder(context: context).run(prompts, caps: caps, from: state, parameters: parameters)
    }
}

// Serves replies decoded beforehand, so the app's own service and pipeline judge and join them.
struct ServedEngine: CleanupEngine {
    let name: String
    let replies: [String: String?]
    var runsInApp: Bool { true }
    var state: ModelState { .ready }
    func load() async throws {}
    func unload() async {}
    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String {
        guard let served = replies[transcript] else { throw CleanupEngineError.generationFailed() }
        guard let reply = served else { throw CleanupEngineError.replyTooLong }
        return reply
    }
}

func passes(_ reply: String?, piece: String, prompt: Prompt) -> Bool {
    guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
    return ReplyFit(transcript: piece, reply: text).suits(prompt) && !(prompt.keepsWhatWasSaid && SpokenLanguage.differs(text, from: piece))
}

// Experiment 2: each dictation the app cleans in sentence runs, cleaned as the app does, one run after another, and
// with all its runs decoded together as one batch; then the same runs again at batch sizes 1 to 16.
func dictationReplayBatch(history: String, out: String, model: String?) async throws {
    let folder = URL(filePath: out)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let prompts = (try? PromptStore.shared.all()) ?? PromptStore.builtIn
    func prompt(of entry: HistoryEntry) -> Prompt { entry.prompt.flatMap { id in prompts.first { $0.id == id } } ?? .tidy }
    let entries = try await replayEntries(history).filter { prompt(of: $0).capsReplyLength }
    let local = LocalModelEngine(model: ModelReference(model ?? SettingsStore.shared.value(CleanupSettings.localModel)), store: .shared)
    try await local.load()
    let replayer = BatchReplayer(local: local)
    _ = await replayer.service.clean("um so this is just a warm up sentence", with: .tidy)
    print(String(
        format: "%d dictations cleaned in runs, load average %.1f, footprint %.0f MB",
        entries.count, loadAverage(), memoryMegabytes().footprint
    ))
    var rows: [ReplayRow] = []
    var chunkRows: [BatchChunkRow] = []
    var sweep: [SweepItem] = []
    for (number, entry) in entries.enumerated() {
        if let replayed = try await replayer.replay(entry, prompt: prompt(of: entry)) {
            rows += replayed.rows
            chunkRows += replayed.chunks
            sweep += replayed.sweep
        }
        if (number + 1) % 25 == 0 {
            print(String(format: "%d dictations, footprint %.0f MB, load average %.1f", number + 1, memoryMegabytes().footprint, loadAverage()))
        }
    }
    try writeLines(rows, to: folder.appending(path: "batch-rows.jsonl"))
    try writeLines(chunkRows, to: folder.appending(path: "batch-chunks.jsonl"))
    printVariants(rows, ["pipeline", "batch"])
    printBatchCorrectness(chunkRows)
    let sweepRows = try await batchSweep(sweep, bench: replayer.bench, engine: local)
    try writeLines(sweepRows, to: folder.appending(path: "batch-sweep.jsonl"))
    await local.unload()
    print(String(format: "footprint %.0f MB after unload", memoryMegabytes().footprint))
}

struct BatchReplayer {
    typealias Call = (transcript: String, instruction: String, growth: ReplyGrowth)

    let local: LocalModelEngine
    let engine: LoggingEngine
    let service: CleanupService
    let pipeline: TextPipeline
    let bench = BatchBench()
    let maxBatch = 16

    init(local: LocalModelEngine) {
        self.local = local
        engine = LoggingEngine(engine: local)
        service = CleanupService(engine: engine, settings: .shared)
        pipeline = TextPipeline(cleanup: service, prompts: .shared, dictionary: .shared, settings: .shared)
    }

    // Nil when the dictation made no clean-up call of the chunked kind, as when its text was only white space.
    func replay(_ entry: HistoryEntry, prompt: Prompt) async throws -> (rows: [ReplayRow], chunks: [BatchChunkRow], sweep: [SweepItem])? {
        let first = await engine.log.replies.count
        let start = ContinuousClock.now
        let result = await pipeline.run(heard: entry.rawText, prompt: prompt).cleanup
        let appSeconds = seconds(since: start)
        let log = engine.log
        let calls: [Call] = await Array(zip(zip(log.heard[first...], log.instructions[first...]), log.growths[first...]).map { ($0.0, $0.1, $1) })
        let appReplies = await Array(log.replies[first...])
        guard !calls.isEmpty, calls.allSatisfy({ $0.growth == Prompt.tidy.growth }) else { return nil }
        let appPasses = calls.indices.map { passes(appReplies[$0], piece: calls[$0].transcript, prompt: prompt) }

        var solo: [DecodedRows] = []
        for call in calls { solo.append(try await local.withLoadedModel { [bench] in try await bench.decode([call], context: $0) }) }
        let batched = try await decodeInBatches(calls)
        let served = ServedEngine(
            name: local.name,
            replies: Dictionary(zip(calls.map(\.transcript), zip(batched.texts, batched.isCutOff).map { $1 ? nil : $0 }), uniquingKeysWith: { one, _ in one })
        )
        let servedPipeline = TextPipeline(
            cleanup: CleanupService(engine: served, settings: .shared), prompts: .shared, dictionary: .shared, settings: .shared
        )
        let servedStart = ContinuousClock.now
        let batchResult = await servedPipeline.run(heard: entry.rawText, prompt: prompt).cleanup
        let batchSeconds = batched.seconds + seconds(since: servedStart)
        let batchPasses = calls.indices.map { !batched.isCutOff[$0] && passes(batched.texts[$0], piece: calls[$0].transcript, prompt: prompt) }
        let rows = [
            replayRow(entry, prompt, variant: "pipeline", result: result, seconds: appSeconds, passing: appPasses),
            replayRow(entry, prompt, variant: "batch", result: batchResult, seconds: batchSeconds, passing: batchPasses)
        ]
        let chunks = calls.indices.map { index in
            let soloTokens = solo[index].tokens[0]
            let same = soloTokens == batched.tokens[index]
            return BatchChunkRow(
                id: shortID(entry.id), index: index, words: SentenceChunks.wordCount(Substring(calls[index].transcript)),
                batchSize: min(calls.count, maxBatch), soloTokens: soloTokens.count, batchTokens: batched.tokens[index].count,
                soloSameAsApp: appReplies[index].map { $0 == solo[index].texts[0] }, batchSameAsSolo: same,
                firstDifference: same ? nil : zip(soloTokens, batched.tokens[index]).prefix { $0 == $1 }.count,
                appPasses: appPasses[index], batchPasses: batchPasses[index]
            )
        }
        let sweep = calls.indices.map { SweepItem(calls[$0].instruction, solo[$0].prompts[0], solo[$0].caps[0], solo[$0].tokens[0]) }
        return (rows, chunks, sweep)
    }

    private func decodeInBatches(_ calls: [Call]) async throws -> (texts: [String], isCutOff: [Bool], tokens: [[Int]], seconds: Double) {
        var texts: [String] = []
        var isCutOff: [Bool] = []
        var tokens: [[Int]] = []
        var total = 0.0
        for group in stride(from: 0, to: calls.count, by: maxBatch).map({ Array(calls[$0 ..< min($0 + maxBatch, calls.count)]) }) {
            let decoded = try await local.withLoadedModel { [bench] in try await bench.decode(group, context: $0) }
            texts += decoded.texts
            isCutOff += decoded.isCutOff
            tokens += decoded.tokens
            total += decoded.seconds
        }
        return (texts, isCutOff, tokens, total)
    }
}

func replayRow(_ entry: HistoryEntry, _ prompt: Prompt, variant: String, result: CleanupResult, seconds: Double, passing: [Bool]) -> ReplayRow {
    let cleaned = passing.filter { $0 }.count
    return ReplayRow(
        id: shortID(entry.id), variant: variant, prompt: ReplayCleaner.label(prompt), measure: ReplayMeasure(heard: entry.rawText, reply: result.text),
        seconds: seconds, status: result.status.rawValue, chunks: passing.count, cleaned: cleaned, skipped: passing.count - cleaned,
        reasons: result.reason.map { [$0.rawValue] } ?? [], sameAsWhole: nil
    )
}

func printBatchCorrectness(_ chunks: [BatchChunkRow]) {
    let checked = chunks.compactMap(\.soloSameAsApp)
    print("\none row against the app: \(checked.filter { $0 }.count) of \(checked.count) replies identical")
    print("batch size | chunks | identical | differ | first difference p50 | p10 | app passes | batch passes")
    for size in Array(Set(chunks.map(\.batchSize))).sorted() + [0] {
        let set = chunks.filter { size == 0 || $0.batchSize == size }
        let differ = set.compactMap(\.firstDifference).map(Double.init)
        print(String(
            format: "%@ | %d | %d | %d | %.0f | %.0f | %d | %d", size == 0 ? "all" : "\(size)", set.count, set.filter(\.batchSameAsSolo).count,
            differ.count, quantile(differ, 0.5), quantile(differ, 0.1), set.filter(\.appPasses).count, set.filter(\.batchPasses).count
        ))
    }
}

typealias SweepItem = (instruction: String, tokens: [Int], cap: Int, solo: [Int])

struct SweepPass {
    var replies: [[Int]] = []
    var seconds = 0.0
    var first = 0.0
    var peak = 0.0
    var footprint = 0.0
}

// The same runs at each batch size, so speed, memory and identity compare on one set; size 4 runs twice, rows rotated.
func batchSweep(_ items: [SweepItem], bench: BatchBench, engine: LocalModelEngine) async throws -> [SweepRow] {
    guard let (instruction, all) = Dictionary(grouping: items, by: \.instruction).max(by: { $0.value.count < $1.value.count }) else { return [] }
    let set = Array(all.prefix(min(256, max(16, all.count / 16 * 16))))
    print(String(format: "\nsweep: %d runs of one instruction, load average %.1f, footprint %.0f MB", set.count, loadAverage(), memoryMegabytes().footprint))
    print("batch size | batches | tokens | seconds | tokens/s | first step s per batch | peak MLX MB | footprint after MB | MLX cache after MB", terminator: "")
    print(" | same as alone | same in other order")
    var rows: [SweepRow] = []
    for size in [1, 2, 4, 8, 16] {
        let batches = stride(from: 0, to: set.count, by: size).map { Array(set[$0 ..< min($0 + size, set.count)]) }
        func pass(rotated: Bool) async throws -> SweepPass {
            var totals = SweepPass()
            for batch in batches {
                let order = rotated ? Array(batch.indices.dropFirst()) + [0] : Array(batch.indices)
                let measured = try await engine.withLoadedModel { context in
                    MLX.Memory.peakMemory = 0
                    let run = try bench.run(order.map { batch[$0].tokens }, caps: order.map { batch[$0].cap }, instruction: instruction, context: context)
                    return (run.replies.map(\.tokens), run.seconds, run.firstStepSeconds, Double(MLX.Memory.peakMemory) / 1_048_576)
                }
                var inOrder = Array(repeating: [Int](), count: batch.count)
                for (position, index) in order.enumerated() { inOrder[index] = measured.0[position] }
                totals.replies += inOrder
                totals.seconds += measured.1
                totals.first += measured.2
                totals.peak = max(totals.peak, measured.3)
                totals.footprint = max(totals.footprint, memoryMegabytes().footprint)
            }
            return totals
        }
        let straight = try await pass(rotated: false)
        let other = size == 4 ? try await pass(rotated: true) : nil
        let tokens = straight.replies.map(\.count).reduce(0, +)
        let row = SweepRow(
            batchSize: size, batches: batches.count, rows: set.count, tokens: tokens, seconds: straight.seconds,
            firstStepSeconds: straight.first / Double(batches.count), peakMegabytes: straight.peak, footprintAfter: straight.footprint,
            cacheMegabytesAfter: Double(MLX.Memory.cacheMemory) / 1_048_576,
            sameAsSolo: zip(straight.replies, set).filter { $0 == $1.solo }.count,
            sameAsOtherOrder: other.map { zip(straight.replies, $0.replies).filter { $0 == $1 }.count }
        )
        rows.append(row)
        print(String(
            format: "%d | %d | %d | %.1f | %.0f | %.3f | %.0f | %.0f | %.0f | %d | %@", size, row.batches, tokens, row.seconds, Double(tokens) / row.seconds,
            row.firstStepSeconds, row.peakMegabytes, row.footprintAfter, row.cacheMegabytesAfter, row.sameAsSolo,
            row.sameAsOtherOrder.map { "\($0)" } ?? "-"
        ))
    }
    return rows
}
