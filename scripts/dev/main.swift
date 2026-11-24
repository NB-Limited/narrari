import Darwin
import Foundation
import NarrariKit

func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

func wordErrors(reference: [String], hypothesis: [String]) -> Int {
    var previous = Array(0...hypothesis.count)
    for (i, word) in reference.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
        for (j, other) in hypothesis.enumerated() {
            current[j + 1] = min(previous[j] + (word == other ? 0 : 1), previous[j + 1] + 1, current[j] + 1)
        }
        previous = current
    }
    return previous[hypothesis.count]
}

func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = (ContinuousClock.now - start).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}

func seconds(_ work: () async throws -> Void) async rethrows -> Double {
    let start = ContinuousClock.now
    try await work()
    return seconds(since: start)
}

func transcribe(_ path: String, with transcriber: any Transcriber) async throws {
    let samples = try await AudioFileDecoder.samples(from: URL(filePath: path))
    var transcript = Transcript(text: "", audioSeconds: 0)
    let elapsed = try await seconds { transcript = try await transcriber.transcribe(samples: samples) }
    print(transcript.text)
    print(String(format: "audio %.1fs, transcribed in %.2fs", transcript.audioSeconds, elapsed))
}

func accuracy(_ directory: String, with transcriber: any Transcriber) async throws {
    let folder = URL(filePath: directory)
    let references = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "txt" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var errors = 0
    var words = 0
    for reference in references {
        let audio = reference.deletingPathExtension().appendingPathExtension("wav")
        let samples = try await AudioFileDecoder.samples(from: audio)
        let expected = normalizedWords(try String(contentsOf: reference, encoding: .utf8))
        let heard = normalizedWords(try await transcriber.transcribe(samples: samples).text)
        errors += wordErrors(reference: expected, hypothesis: heard)
        words += expected.count
    }
    print(String(format: "%d clips, %d words, word error %.1f%%", references.count, words, 100 * Double(errors) / Double(max(words, 1))))
}

struct CleanupSample: Decodable {
    let id: String
    let text: String
    let facts: [String]
}

struct CleanupRun {
    var seconds: [Double] = []
    var kept = 0
    var refused = 0
    var report = ""
}

func cleanup(_ samplesPath: String, outputsPath: String, models: [String]) async throws {
    let samples = try JSONDecoder().decode([CleanupSample].self, from: Data(contentsOf: URL(filePath: samplesPath)))
    var outputs = ""
    print("model | avg s | worst s | kept every fact | refused | size GB | load s")
    for model in models {
        let engine = LocalModelEngine(model: ModelReference(model), store: .shared) { state in
            if case .failed(let reason) = state { print("\(model) failed: \(reason)") }
        }
        try await engine.load()
        await engine.unload()
        let loadTime = try await seconds { try await engine.load() }
        let service = CleanupService(engine: engine, settings: .shared)
        _ = await service.clean("um so this is just a warm up sentence", with: .tidy)

        var run = CleanupRun()
        for sample in samples {
            let start = ContinuousClock.now
            let result = await service.clean(sample.text, with: .tidy)
            run.seconds.append(seconds(since: start))
            let missing = sample.facts.filter { !result.text.localizedCaseInsensitiveContains($0) }
            if result.status == .skipped { run.refused += 1 } else if missing.isEmpty { run.kept += 1 }
            run.report += "### \(sample.id)\n\nin:  \(sample.text)\n\nout: \(result.text)\n\n"
            run.report += "status \(result.status.rawValue) \(result.reason?.rawValue ?? ""), missing \(missing), "
            run.report += "\(String(format: "%.2fs", run.seconds.last ?? 0))\n\n"
        }
        let average = run.seconds.reduce(0, +) / Double(max(run.seconds.count, 1))
        let size = Double(try engine.bytesOnDisk()) / 1e9
        print(String(
            format: "%@ | %.2f | %.2f | %d/%d | %d | %.2f | %.2f",
            model, average, run.seconds.max() ?? 0, run.kept, samples.count, run.refused, size, loadTime
        ))
        outputs += "## \(model)\n\n\(run.report)"
        await engine.unload()
    }
    try outputs.write(to: URL(filePath: outputsPath), atomically: true, encoding: .utf8)
    print("outputs written to \(outputsPath)")
}

struct LengthSample: Decodable {
    let id: String
    let text: String
}

// Clean-up time by dictation length and prompt, warm and right after an idle unload. Reply tokens and tokens per second
// go to the log as cleanup-reply-tokens and cleanup-tokens-per-second.
func cleanupSpeed(_ samplesPath: String, models: [String], repeats: Int = 5) async throws {
    let samples = try JSONDecoder().decode([LengthSample].self, from: Data(contentsOf: URL(filePath: samplesPath)))
    print("model | sample | prompt | runs | cleaned | p50 s | max s | reasons")
    for model in models {
        let engine = LocalModelEngine(model: ModelReference(model), store: .shared)
        try await engine.load()
        await engine.unload()
        let loadTime = try await seconds { try await engine.load() }
        print(String(format: "%@ reload %.2fs", model, loadTime))
        let service = CleanupService(engine: engine, settings: .shared)
        _ = await service.clean("um so this is just a warm up sentence", with: .tidy)

        func report(_ label: String, _ prompt: Prompt, _ runs: [(Double, CleanupResult)]) {
            let times = runs.map(\.0).sorted()
            let reasons = Set(runs.compactMap { $0.1.reason?.rawValue }).sorted().joined(separator: ",")
            print(String(
                format: "%@ | %@ | %@ | %d | %d | %.2f | %.2f | %@", ModelReference(model).displayName, label, prompt.name,
                runs.count, runs.filter { $0.1.status == .cleaned }.count, times[times.count / 2], times.last ?? 0, reasons
            ))
        }
        for sample in samples {
            for prompt in [Prompt.tidy, .email] {
                var runs: [(Double, CleanupResult)] = []
                for _ in 0..<repeats {
                    let start = ContinuousClock.now
                    let result = await service.clean(sample.text, with: prompt)
                    runs.append((seconds(since: start), result))
                }
                report(sample.id, prompt, runs)
            }
        }
        // As at a key press after an idle unload: the load starts, and the dictation is released while it runs.
        for sample in samples {
            var runs: [(Double, CleanupResult)] = []
            for _ in 0..<repeats {
                await engine.unload()
                let loading = Task { try await engine.load() }
                try await Task.sleep(for: .milliseconds(50))
                let start = ContinuousClock.now
                let result = await service.clean(sample.text, with: .tidy)
                runs.append((seconds(since: start), result))
                _ = try? await loading.value
            }
            report(sample.id + " after unload", .tidy, runs)
        }
        await engine.unload()
    }
}

// Unload, reload and Tidy each sample, as after an idle unload. With greedy decoding a sound reload gives the reply
// the first load gave, so any other reply is the defect. Round 0 is the first load, with every built-in prompt.
func cleanupReload(rounds: Int, model: String, samplesPaths: [String]) async throws {
    let samples = try samplesPaths.flatMap {
        try JSONDecoder().decode([LengthSample].self, from: Data(contentsOf: URL(filePath: $0)))
    }
    let engine = LocalModelEngine(model: ModelReference(model), store: .shared)
    let service = CleanupService(engine: engine, settings: .shared)
    try await engine.load()
    print("round\tprompt\tsample\tstatus\treason\twords in\twords out\tcontent kept\tadded\tsame\tfootprint MB\treply")
    func row(_ round: Int, _ prompt: Prompt, _ sample: LengthSample, _ result: CleanupResult, same: Bool) {
        let fit = ReplyFit(transcript: sample.text, reply: result.text)
        print(String(
            format: "%d\t%@\t%@\t%@\t%@\t%d\t%d\t%.3f\t%.3f\t%@\t%.0f\t%@", round, prompt.name, sample.id,
            result.status.rawValue, result.reason?.rawValue ?? "-", fit.transcriptWords, fit.replyWords, fit.contentKept,
            fit.added, same ? "yes" : "no", memoryMegabytes().footprint, result.text.replacingOccurrences(of: "\n", with: " ")
        ))
    }
    var first: [String: CleanupResult] = [:]
    for prompt in [Prompt.tidy, .email, .message] {
        for sample in samples {
            let result = await service.clean(sample.text, with: prompt)
            if prompt == .tidy { first[sample.id] = result }
            row(0, prompt, sample, result, same: true)
        }
    }
    var changed = 0
    for round in stride(from: 1, through: rounds, by: 1) {
        for sample in samples {
            await engine.unload()
            try await engine.load()
            let result = await service.clean(sample.text, with: .tidy)
            let same = result == first[sample.id]
            if !same { changed += 1 }
            row(round, .tidy, sample, result, same: same)
        }
    }
    print("summary\t\(model)\t\(changed) of \(rounds * samples.count) replies after a reload differ from the first load")
}

func loadedParakeet(dictionary: DictionaryStore? = nil) async throws -> ParakeetTranscriber {
    var vocabulary: Vocabulary?
    if let dictionary {
        let words = try dictionary.load().words
        if !words.isEmpty {
            let prepared = Vocabulary(store: .shared, settings: .shared)
            let loadTime = await seconds { await prepared.prepare(words: words) }
            print(String(format: "vocabulary of %d words ready in %.2fs", words.count, loadTime))
            vocabulary = prepared
        }
    }
    let transcriber = ParakeetTranscriber(store: .shared, settings: .shared, vocabulary: vocabulary) { state in
        if case .failed(let reason) = state { print("model failed: \(reason)") }
    }
    let loadTime = try await seconds { try await transcriber.load() }
    print(String(format: "model ready in %.2fs", loadTime))
    return transcriber
}

func localEngine(model: String?) async -> LocalModelEngine {
    let engine = LocalModelEngine(model: ModelReference(model ?? SettingsStore.shared.value(CleanupSettings.localModel)), store: .shared)
    // Like the app after start-up: a model on disk is loaded, a missing one is never downloaded here.
    if (try? engine.bytesOnDisk()) ?? 0 > 0 {
        do {
            let loadTime = try await seconds { try await engine.load() }
            print(String(format: "clean-up model ready in %.2fs", loadTime))
        } catch {
            print("clean-up model failed to load: \(error)")
        }
    }
    return engine
}

func pipeline(_ text: String, engine: any CleanupEngine, dictionary: DictionaryStore, isCleanupOn: Bool) async {
    let pipeline = TextPipeline(cleanup: CleanupService(engine: engine, settings: .shared), prompts: .shared, dictionary: dictionary, settings: .shared)
    let start = ContinuousClock.now
    let result = await pipeline.run(text, prompt: .tidy, cleanup: isCleanupOn ? .on : .off(.switchedOff))
    print("prompt:  \(result.prompt.name)\(result.isTriggered ? " (trigger word)" : "")")
    print("cleanup: \(result.cleanup.status.rawValue) \(result.cleanup.reason?.rawValue ?? "") model \(result.cleanup.model)")
    print(String(format: "time:    %.2fs", seconds(since: start)))
    print("final:   \(result.finalText)")
}

func remote(_ address: String, model: String, file: String, dictionary: DictionaryStore) async throws {
    let configuration = RemoteTranscriber.Configuration(address: try ServiceAddress(address), model: model)
    let transcriber = FallbackTranscriber(
        primary: RemoteTranscriber(configuration, dictionary: dictionary),
        fallback: try await loadedParakeet()
    )
    let samples = try await AudioFileDecoder.samples(from: URL(filePath: file))
    let transcript = try await transcriber.transcribe(samples: samples)
    print("text:     \(transcript.text)")
    print("via:      \(transcript.fallbackReason.map { "local model, outside service \($0.rawValue)" } ?? "outside service")")
}

func memoryMegabytes() -> (footprint: Double, resident: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { return (.nan, .nan) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
}

func milliseconds(_ values: [Double], at fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[Int(Double(sorted.count - 1) * fraction)] * 1000
}

func spread(_ values: [Double]) -> String {
    String(
        format: "p50 %.1f ms, p95 %.1f ms, max %.1f ms",
        milliseconds(values, at: 0.5), milliseconds(values, at: 0.95), milliseconds(values, at: 1)
    )
}

// The final and the preview model, as the app holds them, with what each adds to memory.
@MainActor
func loadedModelPair() async throws -> (final: ParakeetTranscriber, preview: ParakeetTranscriber) {
    let before = memoryMegabytes()
    let final = try await loadedParakeet()
    let afterFinal = memoryMegabytes()
    let previewModel = ParakeetTranscriber(store: .shared, settings: .shared)
    let start = ContinuousClock.now
    try await previewModel.load()
    let previewLoad = seconds(since: start)
    let afterPreview = memoryMegabytes()
    print(String(format: "preview model ready in %.2fs", previewLoad))
    print(String(
        format: "memory footprint: final model %.0f MB, preview model %.0f MB more; resident: %.0f MB, %.0f MB more",
        afterFinal.footprint - before.footprint, afterPreview.footprint - afterFinal.footprint,
        afterFinal.resident - before.resident, afterPreview.resident - afterFinal.resident
    ))
    return (final, previewModel)
}

// Key release lands at every point of the preview's half-second beat, the way a real release would.
@MainActor
func previewLatency(_ files: [String]) async throws {
    let trials = 80
    let (final, previewModel) = try await loadedModelPair()
    var start = ContinuousClock.now
    let preview = LivePreview(transcriber: previewModel)
    func pause(_ trial: Int) -> Duration { .seconds(0.5 + Double(trial) / Double(trials) * 0.6) }
    for file in files {
        let samples = try await AudioFileDecoder.samples(from: URL(filePath: file))
        let window = Array(samples.suffix(14 * 16_000))
        var passes: [Double] = []
        for _ in 0..<trials {
            start = .now
            _ = try await previewModel.transcribe(samples: window)
            passes.append(seconds(since: start))
        }
        // The baseline idles as long as the trials do, because a pass right after another runs on warmer hardware.
        var alone: [Double] = []
        for trial in 0..<trials {
            try await Task.sleep(for: pause(trial))
            start = .now
            _ = try await final.transcribe(samples: samples)
            alone.append(seconds(since: start))
        }
        let expected = try await final.transcribe(samples: samples).text

        var released: [Double] = []
        var updates = 0
        for trial in 0..<trials {
            preview.start(reading: { Array(samples.suffix($0)) }, publish: { _ in updates += 1 })
            try await Task.sleep(for: pause(trial))
            preview.stop()
            start = .now
            let text = try await final.transcribe(samples: samples).text
            released.append(seconds(since: start))
            if text != expected { print("final text differs on trial \(trial)") }
        }
        let added = (milliseconds(released, at: 0.95) - milliseconds(alone, at: 0.95))
        print(String(format: "%@: audio %.1fs", (file as NSString).lastPathComponent, Double(samples.count) / 16_000))
        print("  preview pass:          \(spread(passes))")
        print("  final, no preview:     \(spread(alone))")
        print("  final at key release:  \(spread(released)), \(updates) preview updates published")
        print(String(format: "  added at p95:          %.1f ms", added))
    }
}

// The same job the Transcribe file window runs, with its own model instance, piece by piece.
func transcribeFile(_ path: String) async throws {
    let start = ContinuousClock.now
    let peak = PeakMemory()
    let watcher = Task {
        while !Task.isCancelled {
            await peak.sample()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    let transcript = try await FileTranscription(store: .shared, settings: .shared, dictionary: .shared).run(URL(filePath: path), upTo: nil) { fraction in
        print(String(format: "\rtranscribing %3.0f%%", fraction * 100), terminator: "")
        fflush(stdout)
    }
    watcher.cancel()
    print("\n\(transcript.text)")
    print(String(
        format: "audio %.1fs, done in %.2fs, peak footprint %.0f MB",
        transcript.audioSeconds, seconds(since: start), await peak.megabytes
    ))
}

actor PeakMemory {
    private(set) var megabytes = 0.0

    func sample() {
        megabytes = max(megabytes, memoryMegabytes().footprint)
    }
}

func modes() throws {
    let slack = "com.tinyspeck.slackmacgap"
    let mail = "com.apple.mail"
    let folder = FileManager.default.temporaryDirectory.appending(path: "narrari-modes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ModeStore(root: folder)
    print("empty store, global default: \(try store.load().globalDefault.name)")

    try store.edit { book in
        try book.add(Mode(id: "casual", name: "casual", promptID: Prompt.message.id))
        try book.add(Mode(id: "formal", name: "formal", promptID: Prompt.email.id))
        try book.setModes(for: slack, ids: ["casual", "formal"], defaultID: "casual")
        try book.setModes(for: mail, ids: ["formal"], defaultID: "formal")
    }
    let book = try store.load()
    var resolver = ModeResolver()
    for (label, app) in [("Slack", slack), ("Mail", mail), ("app with no modes", "com.example.unlisted")] {
        let mode = resolver.resolve(for: app, in: book)
        print("\(label): \(mode.name) (prompt \(book.mode(id: mode.id)?.promptID ?? ""))")
    }
    for turn in 1...2 {
        print("cycle Slack \(turn): \(resolver.cycle(for: slack, in: book)?.name ?? "nothing to cycle")")
    }
    print("cycle Mail: \(resolver.cycle(for: mail, in: book)?.name ?? "nothing to cycle")")

    _ = resolver.cycle(for: slack, in: book)
    print("Slack after a manual switch: \(resolver.resolve(for: slack, in: book).name)")
    print("then Mail: \(resolver.resolve(for: mail, in: book).name)")
    print("back to Slack: \(resolver.resolve(for: slack, in: book).name)")

    try store.edit { try $0.delete("casual") }
    let after = try store.load()
    print("casual deleted, Slack: \(after.modes(for: slack).map(\.name)), default \(after.defaultMode(for: slack).name)")
    do {
        try store.edit { try $0.delete(Mode.dictation.id) }
    } catch {
        print("deleting the global default: \(error)")
    }
}

func cleanupModels(_ given: some Collection<String>) -> [String] {
    given.isEmpty ? ModelCatalogue.cleanup.map(\.id) : Array(given)
}

func option(_ name: String, in arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func flag(_ name: String, in arguments: inout [String]) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

var arguments = Array(CommandLine.arguments.dropFirst())
let dictionaryFolder = option("--dictionary", in: &arguments)
let dictionary = dictionaryFolder.map { DictionaryStore(root: URL(filePath: $0)) }
let cleanupModel = option("--model", in: &arguments)
let isCleanupOff = flag("--off", in: &arguments)
let chatAddress = option("--chat", in: &arguments)
let replayMinutes = option("--minutes", in: &arguments).flatMap(Double.init)
let fastPPM = option("--fast-ppm", in: &arguments).flatMap(Double.init) ?? 0
let rigOnly = option("--only", in: &arguments)
let isRigQuick = flag("--quick", in: &arguments)
let liveMinutes = option("--live-until", in: &arguments).flatMap(Double.init) ?? (flag("--live", in: &arguments) ? .infinity : nil)
let usage = """
    usage: narrari-dev transcribe [--dictionary <folder>] <audio or video file>
           narrari-dev transcribe-file <audio or video file>
           narrari-dev accuracy <folder of NAME.wav + NAME.txt>
           narrari-dev cleanup <samples.json> <outputs file> [<model id>...]
           narrari-dev cleanup-speed <samples.json> [<model id>...]
           narrari-dev cleanup-reload [--model <id>] <rounds> <samples.json>...
           narrari-dev prompt-bench [--model <id>] <samples.json> <prompts.json> <rows.jsonl>
           (no model id: every clean-up model the app offers)
           narrari-dev pipeline [--dictionary <folder>] [--model <id>] [--chat <address>] [--off] "<transcript>"
           narrari-dev remote [--dictionary <folder>] <address> <model> <audio file>
           narrari-dev preview-latency <audio file>...
           narrari-dev modes
           narrari-dev meeting replay [--minutes <n>] [--fast-ppm <n>] [--live | --live-until <minutes>]
                                      <mic file> <system file> <scratch data folder>
           narrari-dev meeting rig [--quick] [--only <scenario name part>]
           narrari-dev meeting models <scratch data folder> <scratch models folder>
           narrari-dev meeting process <scratch data folder> <scratch models folder>
           narrari-dev meeting summaries <scratch data folder> <scratch models folder> <out folder> [<model id>...]
    """

do {
    switch (arguments.first, arguments.count) {
    case ("transcribe", 2): try await transcribe(arguments[1], with: try await loadedParakeet(dictionary: dictionary))
    case ("transcribe-file", 2): try await transcribeFile(arguments[1])
    case ("accuracy", 2): try await accuracy(arguments[1], with: try await loadedParakeet())
    case ("cleanup", 3...): try await cleanup(arguments[1], outputsPath: arguments[2], models: cleanupModels(arguments[3...]))
    case ("cleanup-speed", 2...): try await cleanupSpeed(arguments[1], models: cleanupModels(arguments[2...]))
    case ("cleanup-reload", 3...):
        for model in cleanupModels(cleanupModel.map { [$0] } ?? []) {
            try await cleanupReload(rounds: Int(arguments[1]) ?? 1, model: model, samplesPaths: Array(arguments[2...]))
        }
    case ("prompt-bench", 4):
        try await promptBench(arguments[1], promptsPath: arguments[2], outputPath: arguments[3], model: cleanupModel)
    case ("pipeline", 2):
        let engine: any CleanupEngine = if let chatAddress {
            ChatClient(address: try ServiceAddress(chatAddress), model: cleanupModel ?? "", key: nil)
        } else {
            await localEngine(model: cleanupModel)
        }
        await pipeline(arguments[1], engine: engine, dictionary: dictionary ?? .shared, isCleanupOn: !isCleanupOff)
    case ("modes", 1): try modes()
    case ("meeting", 5) where arguments[1] == "replay":
        try await meetingReplay(
            (arguments[2], arguments[3]), into: arguments[4], minutes: replayMinutes, fastPPM: fastPPM, liveMinutes: liveMinutes
        )
    case ("meeting", 2) where arguments[1] == "rig":
        if try await !recordingRig(isQuick: isRigQuick, only: rigOnly) { exit(1) }
    case ("meeting", 7) where arguments[1] == "rig-play":
        try await rigPlay(Array(arguments[2...]))
    case ("meeting", 4) where arguments[1] == "models":
        try await meetingModels(try ScratchMeetings(data: arguments[2], models: arguments[3]))
    case ("meeting", 4) where arguments[1] == "process":
        try await meetingProcess(try ScratchMeetings(data: arguments[2], models: arguments[3]))
    case ("meeting", 5...) where arguments[1] == "summaries":
        let scratch = try ScratchMeetings(data: arguments[2], models: arguments[3])
        try await meetingSummaries(scratch, out: arguments[4], models: cleanupModels(arguments[5...]))
    case ("preview-latency", 2...): try await previewLatency(Array(arguments[1...]))
    case ("remote", 4):
        try await remote(arguments[1], model: arguments[2], file: arguments[3], dictionary: dictionary ?? .shared)
    default:
        print(usage)
        exit(2)
    }
} catch {
    print("failed: \(error)")
    exit(1)
}
