import Foundation
import NarrariKit

struct AheadRow: Codable {
    let id: String
    let audioSeconds: Double
    let finalWords: Int
    let seenWords: Int
    let seenLooseWords: Int
    let finalChunks: Int
    let finalPassSeconds: Double
    // Clean-up seconds the model would still need at key release, from the chunk speed fit of the text replay.
    let leftSeconds: Double?
    let prefixAudioSeconds: [Double]
    let prefixPassSeconds: [Double]
}

// Experiment 2: each kept recording of 15 s or more transcribed every 5 s as if the speaker were still talking, to find
// how much of the final text was already a finished chunk, and so could have been cleaned before the key was released.
func dictationReplayAhead(history: String, out: String, maxWords: Int = 40) async throws {
    let folder = URL(filePath: out)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = HistoryStore(root: URL(filePath: history))
    let entries = try await replayEntries(history).filter {
        $0.durationMs >= 15_000 && $0.audioFailure == nil && FileManager.default.fileExists(atPath: store.audioURL(for: $0.id).path)
    }
    let speed = try? readLines(ChunkRow.self, from: folder.appending(path: "text-chunks.jsonl"))
        .filter { $0.variant == "pipeline" && $0.status == "cleaned" && !$0.seconds.isNaN }
    let fit = speed.map { linearFit($0.map { (Double($0.measure.heardWords), $0.seconds) }) }
    let transcriber = try await loadedParakeet(dictionary: .shared)
    print(String(format: "%d recordings, load average %.1f, footprint %.0f MB", entries.count, loadAverage(), memoryMegabytes().footprint))
    let rate = SpeechAudio.sampleRate
    let step = Int(5 * rate)
    var rows: [AheadRow] = []
    for entry in entries {
        let samples = try await AudioFileDecoder.samples(from: store.audioURL(for: entry.id))
        var seen = Set<String>()
        var seenLoose = Set<String>()
        var prefixAudio: [Double] = []
        var prefixPass: [Double] = []
        for end in stride(from: step, to: samples.count, by: step) {
            let start = ContinuousClock.now
            let text = try await transcriber.transcribe(samples: Array(samples.prefix(end))).text
            prefixPass.append(seconds(since: start))
            prefixAudio.append(Double(end) / rate)
            let finished = SentenceChunks(text, maxWords: maxWords).pieces.dropLast()
            seen.formUnion(finished)
            seenLoose.formUnion(finished.map(looseKey))
        }
        let start = ContinuousClock.now
        let final = try await transcriber.transcribe(samples: samples).text
        let finalPass = seconds(since: start)
        let pieces = SentenceChunks(final, maxWords: maxWords).pieces
        let words = pieces.map { SentenceChunks.wordCount(Substring($0)) }
        let left = zip(pieces, words).filter { !seen.contains($0.0) }.map(\.1)
        rows.append(AheadRow(
            id: shortID(entry.id), audioSeconds: Double(samples.count) / rate, finalWords: words.reduce(0, +),
            seenWords: words.reduce(0, +) - left.reduce(0, +),
            seenLooseWords: zip(pieces, words).filter { seenLoose.contains(looseKey($0.0)) }.map(\.1).reduce(0, +),
            finalChunks: pieces.count, finalPassSeconds: finalPass,
            leftSeconds: fit.map { fit in left.map { fit.intercept + fit.slope * Double($0) }.reduce(0, +) },
            prefixAudioSeconds: prefixAudio, prefixPassSeconds: prefixPass
        ))
    }
    print(String(format: "footprint %.0f MB at the end", memoryMegabytes().footprint))
    try writeLines(rows, to: folder.appending(path: "ahead-rows.jsonl"))
    let whole = try? readLines(ReplayRow.self, from: folder.appending(path: "text-rows.jsonl")).filter { $0.variant == "whole" }
    printAheadSummary(rows, whole: whole)
}

func looseKey(_ text: String) -> String {
    text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
}

func printAheadSummary(_ rows: [AheadRow], whole: [ReplayRow]?) {
    print(String(format: "\n%d recordings, %.0f s of audio", rows.count, rows.map(\.audioSeconds).reduce(0, +)))
    let passes = rows.flatMap { row in zip(row.prefixAudioSeconds + [row.audioSeconds], row.prefixPassSeconds + [row.finalPassSeconds]) }
    print("prefix audio s | passes | pass p50 s | pass p90 s")
    for (label, range) in [("5-15", 0.0...15.0), ("15-30", 15.001...30.0), ("30-60", 30.001...60.0), ("60+", 60.001...Double.infinity)] {
        let times = passes.filter { range.contains($0.0) }.map(\.1)
        print(String(format: "%@ | %d | %.2f | %.2f", label, times.count, quantile(times, 0.5), quantile(times, 0.9)))
    }
    let shares = rows.map { Double($0.seenWords) / Double(max($0.finalWords, 1)) }
    let loose = rows.map { Double($0.seenLooseWords) / Double(max($0.finalWords, 1)) }
    let left = rows.map { Double($0.finalWords - $0.seenWords) }
    let finals = rows.map { Double($0.finalWords) }
    print(String(
        format: "seen ahead, exact: mean %.2f p10 %.2f p50 %.2f; loose: mean %.2f p10 %.2f p50 %.2f",
        shares.reduce(0, +) / Double(max(shares.count, 1)), quantile(shares, 0.1), quantile(shares, 0.5),
        loose.reduce(0, +) / Double(max(loose.count, 1)), quantile(loose, 0.1), quantile(loose, 0.5)
    ))
    print(String(
        format: "words left at release p50 %.0f p90 %.0f, of dictation words p50 %.0f p90 %.0f",
        quantile(left, 0.5), quantile(left, 0.9), quantile(finals, 0.5), quantile(finals, 0.9)
    ))
    guard let whole else { return }
    let cleanups = Dictionary(whole.map { ($0.id, $0.seconds) }, uniquingKeysWith: { first, _ in first })
    let paired = rows.compactMap { row in
        cleanups[row.id].flatMap { today in row.leftSeconds.map { (row.finalPassSeconds + today, row.finalPassSeconds + $0) } }
    }
    print(String(
        format: "estimate, release to paste for %d: today p50 %.2f p90 %.2f s, with clean-ahead p50 %.2f p90 %.2f s",
        paired.count, quantile(paired.map(\.0), 0.5), quantile(paired.map(\.0), 0.9), quantile(paired.map(\.1), 0.5), quantile(paired.map(\.1), 0.9)
    ))
}
