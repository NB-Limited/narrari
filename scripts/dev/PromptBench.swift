import Foundation
import NarrariKit

struct PromptBenchSample: Decodable {
    let id: String
    let text: String
}

actor LastReply {
    private(set) var text: String?
    func set(_ new: String?) { text = new }
}

// Passes through to the local model and keeps its reply, so a reply the service turned down can still be read.
struct RecordingEngine: CleanupEngine {
    let engine: LocalModelEngine
    let last = LastReply()
    var name: String { engine.name }
    var runsInApp: Bool { engine.runsInApp }
    var state: ModelState { get async { await engine.state } }
    func load() async throws { try await engine.load() }
    func unload() async { await engine.unload() }
    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String {
        await last.set(nil)
        let reply = try await engine.rewrite(transcript, instruction: instruction, growth: growth)
        await last.set(reply)
        return reply
    }
}

struct PromptBenchRow: Encodable {
    let prompt: String
    let sample: String
    let status: String
    let reason: String?
    let seconds: Double
    let text: String
    let reply: String?
    let contentKept: Double
    let added: Double
    let unspokenLines: Int
}

// Every prompt in a JSON list of prompts over every sample, through CleanupService as the app runs it, one JSON line each.
// A prompt's id decides whether the built-in language and fit rules apply, so a candidate for a built-in reuses one's id.
func promptBench(_ samplesPath: String, promptsPath: String, outputPath: String, model: String?) async throws {
    let samples = try JSONDecoder().decode([PromptBenchSample].self, from: Data(contentsOf: URL(filePath: samplesPath)))
    let prompts = try JSONDecoder().decode([Prompt].self, from: Data(contentsOf: URL(filePath: promptsPath)))
    let local = LocalModelEngine(model: ModelReference(model ?? SettingsStore.shared.value(CleanupSettings.localModel)), store: .shared)
    try await local.load()
    let engine = RecordingEngine(engine: local)
    let service = CleanupService(engine: engine, settings: .shared)
    _ = await service.clean("um so this is just a warm up sentence", with: .tidy)
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    let output = try FileHandle(forWritingTo: URL(filePath: outputPath))
    let encoder = JSONEncoder()
    for prompt in prompts {
        var times: [Double] = []
        var cleaned = 0
        for sample in samples {
            let start = ContinuousClock.now
            let result = await service.clean(sample.text, with: prompt)
            let elapsed = seconds(since: start)
            times.append(elapsed)
            if result.status == .cleaned { cleaned += 1 }
            let reply = await engine.last.text
            let fit = ReplyFit(transcript: sample.text, reply: reply ?? result.text)
            let row = PromptBenchRow(
                prompt: prompt.name, sample: sample.id, status: result.status.rawValue, reason: result.reason?.rawValue,
                seconds: elapsed, text: result.text, reply: reply, contentKept: fit.contentKept, added: fit.added,
                unspokenLines: fit.unspokenLines
            )
            try output.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
        }
        let sorted = times.sorted()
        print(String(
            format: "%@ | cleaned %d/%d | p50 %.2fs | max %.2fs", prompt.name, cleaned, samples.count,
            sorted[sorted.count / 2], sorted.last ?? 0
        ))
    }
    try output.close()
    await local.unload()
}
