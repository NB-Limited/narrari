import Foundation
import NarrariKit

struct PieceRow: Codable {
    let id: String
    let setting: String
    let audioSeconds: Double
    let pieces: Int
    let forcedCuts: Int
    // Cuts whose 256 ms block Silero, as SpeechDetector reads it, calls no speech.
    let cutsInSilence: Int
    let wholeWords: Int
    let errors: Int
    let differingNearCut: Int
    let differingElsewhere: Int
    let wordsNearCut: Int
    let stopsAtCut: Int
    let stopsWholeLacks: Int
    let capitalsWholeLacks: Int
    let refereeWhole: Int
    let refereePieces: Int
    let refereeNeither: Int
    let refereeErrorsWhole: Int?
    let refereeErrorsPieces: Int?
    let piecePasses: [Double]
    let lastPieceSeconds: Double
    let lastPass: Double
    let wholePass: Double
    let todayEstimate: Double
    let piecesEstimate: Double
}

// The chunk clean-up speed the text replay measured: 0.058 s a call and 0.0125 s a word.
func cleanupEstimate(words: Int) -> Double { words == 0 ? 0 : 0.058 + 0.0125 * Double(words) }

struct PieceTranscript {
    let range: Range<Int>
    let readyAt: Int
    let text: String
    let seconds: Double
}

struct PieceRecording {
    let id: String
    let samples: [Float]
    let whole: String
    let wholePass: Double
    let referee: String?
    let speech: [Bool]
    var cache: [Range<Int>: (text: String, seconds: Double)] = [:]

    var rate: Double { SpeechAudio.sampleRate }

    mutating func transcribe(_ range: Range<Int>, with transcriber: ParakeetTranscriber) async throws -> (text: String, seconds: Double) {
        if let known = cache[range] { return known }
        let result = try await Self.pass(Array(samples[range]), with: transcriber)
        cache[range] = result
        return result
    }

    // FluidAudio turns down less than 0.3 s; it pads every input to 15 s with zeros anyway.
    static func pass(_ samples: [Float], with transcriber: ParakeetTranscriber) async throws -> (text: String, seconds: Double) {
        let least = Int(0.3 * SpeechAudio.sampleRate)
        let padded = samples.count < least ? samples + [Float](repeating: 0, count: least - samples.count) : samples
        let start = ContinuousClock.now
        let text = try await transcriber.transcribe(samples: padded).text
        return (text, seconds(since: start))
    }

    mutating func pieces(_ cuts: [PieceCut], with transcriber: ParakeetTranscriber) async throws -> [PieceTranscript] {
        let bounds = [0] + cuts.map(\.at) + [samples.count]
        var pieces: [PieceTranscript] = []
        for index in 0..<(bounds.count - 1) {
            let range = bounds[index]..<max(bounds[index], bounds[index + 1])
            let result = try await transcribe(range, with: transcriber)
            let readyAt = index < cuts.count ? cuts[index].decidedAt : samples.count
            pieces.append(PieceTranscript(range: range, readyAt: readyAt, text: result.text, seconds: result.seconds))
        }
        return pieces
    }

    // One model and one clean-up worker, each taking pieces in order as soon as they are ready.
    func releaseToPaste(_ pieces: [PieceTranscript]) -> Double {
        var heard = 0.0
        var cleaned = 0.0
        for piece in pieces {
            heard = max(heard, Double(piece.readyAt) / rate) + piece.seconds
            cleaned = max(cleaned, heard) + cleanupEstimate(words: normalizedWords(piece.text).count)
        }
        return cleaned - Double(samples.count) / rate
    }
}

struct PieceComparison {
    let errors: Int
    let near: Int
    let elsewhere: Int
    let wordsNearCut: Int
    let stops: Int
    let stopsWholeLacks: Int
    let capitalsWholeLacks: Int
    let referee: (whole: Int, pieces: Int, neither: Int)

    init(whole: TranscriptWords, pieces: [PieceTranscript], judge: TranscriptWords?) {
        let joined = TranscriptWords(pieces.map(\.text).joined(separator: " "))
        var starts: [Int] = []
        var total = 0
        for piece in pieces.dropLast() {
            total += normalizedWords(piece.text).count
            if total > 0, starts.last != total { starts.append(total) }
        }
        starts = starts.filter { $0 < joined.words.count }
        let alignment = WordAlignment(whole.words, joined.words)
        let hunks = alignment.hunks(whole.words, joined.words)
        func isNear(_ hunk: WordAlignment.Hunk) -> Bool {
            starts.contains { hunk.right.lowerBound <= $0 + 2 && max(hunk.right.upperBound, hunk.right.lowerBound + 1) >= $0 - 2 }
        }
        errors = alignment.errors
        near = hunks.filter(isNear).map(\.weight).reduce(0, +)
        elsewhere = hunks.filter { !isNear($0) }.map(\.weight).reduce(0, +)
        wordsNearCut = joined.words.indices.filter { word in starts.contains { $0 - 2 <= word && word < $0 + 2 } }.count
        let partners = alignment.leftPartners(rightCount: joined.words.count)
        let ending = starts.filter { joined.endsSentence(at: $0 - 1) }
        stops = ending.count
        stopsWholeLacks = ending.filter { partners[$0 - 1].map { !whole.endsSentence(at: $0) } ?? false }.count
        capitalsWholeLacks = starts.filter { joined.startsCapital(at: $0) && partners[$0].map { !whole.startsCapital(at: $0) } ?? false }.count
        referee = judge.map { Self.judge(hunks, whole: whole.words, pieces: joined.words, referee: $0.words) } ?? (0, 0, 0)
    }

    static func judge(_ hunks: [WordAlignment.Hunk], whole: [String], pieces: [String], referee: [String]) -> (whole: Int, pieces: Int, neither: Int) {
        let alignment = WordAlignment(whole, referee)
        var tally = (whole: 0, pieces: 0, neither: 0)
        for hunk in hunks {
            let span = Array(referee[alignment.rightSpan(of: hunk.left, leftCount: whole.count, rightCount: referee.count)])
            if span == Array(whole[hunk.left]) {
                tally.whole += hunk.weight
            } else if span == Array(pieces[hunk.right]) {
                tally.pieces += hunk.weight
            } else {
                tally.neither += hunk.weight
            }
        }
        return tally
    }
}

// Experiment 3: each kept recording of 15 s or more cut at pauses as it is heard, every piece transcribed once, and the
// joined pieces held against one pass over the whole audio, with the other speech model on disk as the referee.
func dictationReplayPieces(history: String, out: String) async throws {
    let folder = URL(filePath: out)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = HistoryStore(root: URL(filePath: history))
    let entries = try await replayEntries(history).filter {
        $0.durationMs >= 15_000 && $0.audioFailure == nil && FileManager.default.fileExists(atPath: store.audioURL(for: $0.id).path)
    }
    let vocabulary = try await preparedVocabulary(.shared)
    let transcriber = try await loadedParakeet(vocabulary: vocabulary, settings: .shared)
    let (referee, refereeName) = try await refereeTranscriber(vocabulary: vocabulary)
    defer { if let refereeName { UserDefaults.standard.removePersistentDomain(forName: refereeName) } }
    let detector = SpeechDetector(store: .shared)
    print(String(format: "%d recordings, load average %.1f, footprint %.0f MB", entries.count, loadAverage(), memoryMegabytes().footprint))
    var rows: [PieceRow] = []
    var repeats: [Bool] = []
    for (index, entry) in entries.enumerated() {
        let url = store.audioURL(for: entry.id)
        var recording = try await heardRecording(shortID(entry.id), url: url, transcriber: transcriber, referee: referee, detector: detector)
        for setting in PieceSetting.sweep {
            rows.append(try await pieceRow(&recording, setting: setting, transcriber: transcriber))
        }
        if repeats.count < 30, let range = recording.cache.keys.min(by: { $0.lowerBound < $1.lowerBound }) {
            let again = try await PieceRecording.pass(Array(recording.samples[range]), with: transcriber)
            repeats.append(again.text == recording.cache[range]?.text)
        }
        if index % 20 == 19 { print(String(format: "%d done, load average %.1f", index + 1, loadAverage())) }
    }
    print(String(format: "footprint %.0f MB, load average %.1f at the end", memoryMegabytes().footprint, loadAverage()))
    try writeLines(rows, to: folder.appending(path: "pieces-rows.jsonl"))
    printPiecesSummary(rows, repeats: repeats, refereeName: referee == nil ? nil : refereeModel?.name)
}

let refereeModel = ParakeetModel.allCases.first { $0 != SettingsStore.shared.value(SpeechSettings.localModel) }

// A throwaway settings suite picks the other model, so the owner's settings stay as they are; nothing is downloaded.
func refereeTranscriber(vocabulary: Vocabulary?) async throws -> (ParakeetTranscriber?, String?) {
    guard let refereeModel, ModelStore.shared.isPresent(refereeModel) else {
        print("no second speech model on disk: no referee")
        return (nil, nil)
    }
    let suite = "narrari-dev-referee-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.featureUnsupported) }
    let settings = SettingsStore(defaults: defaults)
    settings.set(refereeModel, for: SpeechSettings.localModel)
    return (try await loadedParakeet(vocabulary: vocabulary, settings: settings, downloadsIfMissing: false), suite)
}

func heardRecording(
    _ id: String, url: URL, transcriber: ParakeetTranscriber, referee: ParakeetTranscriber?, detector: SpeechDetector
) async throws -> PieceRecording {
    let samples = try await AudioFileDecoder.samples(from: url)
    let whole = try await PieceRecording.pass(samples, with: transcriber)
    var refereeText: String?
    if let referee { refereeText = try await PieceRecording.pass(samples, with: referee).text }
    return PieceRecording(
        id: id, samples: samples, whole: whole.text, wholePass: whole.seconds, referee: refereeText, speech: try await detector.speech(in: url)
    )
}

func pieceRow(_ recording: inout PieceRecording, setting: PieceSetting, transcriber: ParakeetTranscriber) async throws -> PieceRow {
    let cuts = PauseCutter(setting: setting).cuts(recording.samples)
    let pieces = try await recording.pieces(cuts, with: transcriber)
    let whole = TranscriptWords(recording.whole)
    let referee = recording.referee.map(TranscriptWords.init)
    let compared = PieceComparison(whole: whole, pieces: pieces, judge: referee)
    let joined = normalizedWords(pieces.map(\.text).joined(separator: " "))
    let block = Int(SpeechDetector.blockSeconds * SpeechAudio.sampleRate)
    let speech = recording.speech
    let last = pieces[pieces.count - 1]
    return PieceRow(
        id: recording.id, setting: setting.label, audioSeconds: Double(recording.samples.count) / recording.rate, pieces: pieces.count,
        forcedCuts: cuts.filter(\.forced).count,
        cutsInSilence: cuts.filter { $0.at / block < speech.count && !speech[$0.at / block] }.count,
        wholeWords: whole.words.count, errors: compared.errors, differingNearCut: compared.near, differingElsewhere: compared.elsewhere,
        wordsNearCut: compared.wordsNearCut, stopsAtCut: compared.stops, stopsWholeLacks: compared.stopsWholeLacks,
        capitalsWholeLacks: compared.capitalsWholeLacks, refereeWhole: compared.referee.whole, refereePieces: compared.referee.pieces,
        refereeNeither: compared.referee.neither,
        refereeErrorsWhole: referee.map { WordAlignment($0.words, whole.words).errors },
        refereeErrorsPieces: referee.map { WordAlignment($0.words, joined).errors },
        piecePasses: pieces.map(\.seconds), lastPieceSeconds: Double(last.range.count) / recording.rate, lastPass: last.seconds,
        wholePass: recording.wholePass, todayEstimate: recording.wholePass + cleanupEstimate(words: whole.words.count),
        piecesEstimate: recording.releaseToPaste(pieces)
    )
}

func printPiecesSummary(_ rows: [PieceRow], repeats: [Bool], refereeName: String?) {
    let settings = PieceSetting.sweep.map(\.label)
    let recordings = Set(rows.map(\.id)).count
    let audio = rows.filter { $0.setting == settings[0] }.map(\.audioSeconds)
    print(String(format: "\n%d recordings, %.0f s of audio, referee %@", recordings, audio.reduce(0, +), refereeName ?? "none"))
    print("\nsetting | pieces | forced cuts | cuts in Silero quiet | WER | p50 | p90 | differing near cut | elsewhere | words near cut"
        + " | stops at cut | stop whole lacks | capital whole lacks")
    for setting in settings {
        let set = rows.filter { $0.setting == setting }
        let cuts = set.map { $0.pieces - 1 }.reduce(0, +)
        let rates = set.map { Double($0.errors) / Double(max($0.wholeWords, 1)) }
        print(String(
            format: "%@ | %d | %d | %d of %d | %.4f | %.4f | %.4f | %d | %d | %d of %d | %d | %d | %d", setting, set.map(\.pieces).reduce(0, +),
            sum(set, \.forcedCuts), sum(set, \.cutsInSilence), cuts, Double(sum(set, \.errors)) / Double(max(sum(set, \.wholeWords), 1)),
            quantile(rates, 0.5), quantile(rates, 0.9), sum(set, \.differingNearCut), sum(set, \.differingElsewhere),
            sum(set, \.wordsNearCut), sum(set, \.wholeWords), sum(set, \.stopsAtCut), sum(set, \.stopsWholeLacks), sum(set, \.capitalsWholeLacks)
        ))
    }
    if refereeName != nil { printReferee(rows, settings: settings) }
    printPieceTimes(rows, settings: settings)
    print("\ndeterminism: \(repeats.filter { $0 }.count) of \(repeats.count) pieces read the same when transcribed again")
}

func sum(_ rows: [PieceRow], _ field: KeyPath<PieceRow, Int>) -> Int { rows.map { $0[keyPath: field] }.reduce(0, +) }

func printReferee(_ rows: [PieceRow], settings: [String]) {
    print("\nsetting | differing words | referee reads as whole | as pieces | neither | referee WER against whole | against pieces")
    for setting in settings {
        let set = rows.filter { $0.setting == setting }
        let words = Double(max(sum(set, \.wholeWords), 1))
        print(String(
            format: "%@ | %d | %d | %d | %d | %.4f | %.4f", setting, sum(set, \.refereeWhole) + sum(set, \.refereePieces) + sum(set, \.refereeNeither),
            sum(set, \.refereeWhole), sum(set, \.refereePieces), sum(set, \.refereeNeither),
            Double(set.compactMap(\.refereeErrorsWhole).reduce(0, +)) / words, Double(set.compactMap(\.refereeErrorsPieces).reduce(0, +)) / words
        ))
    }
}

func printPieceTimes(_ rows: [PieceRow], settings: [String]) {
    print("\nsetting | piece pass p50 s | p90 | audio left p50 s | p90 | max | last pass p50 s | p90 | whole pass p50 s | p90 | model s pieces | whole")
    for setting in settings {
        let set = rows.filter { $0.setting == setting }
        let passes = set.flatMap(\.piecePasses)
        let left = set.map(\.lastPieceSeconds)
        print(String(
            format: "%@ | %.3f | %.3f | %.1f | %.1f | %.1f | %.3f | %.3f | %.3f | %.3f | %.0f | %.0f", setting, quantile(passes, 0.5), quantile(passes, 0.9),
            quantile(left, 0.5), quantile(left, 0.9), left.max() ?? .nan, quantile(set.map(\.lastPass), 0.5), quantile(set.map(\.lastPass), 0.9),
            quantile(set.map(\.wholePass), 0.5), quantile(set.map(\.wholePass), 0.9), passes.reduce(0, +), set.map(\.wholePass).reduce(0, +)
        ))
    }
    print("\nestimate, release to paste | audio s | recordings | today p50 s | p90 | pieces p50 s | p90")
    let buckets: [(String, Range<Double>)] = [("15-30", 0..<30), ("30-60", 30..<60), ("60+", 60..<Double.infinity), ("all", 0..<Double.infinity)]
    for setting in settings {
        for (label, range) in buckets {
            let set = rows.filter { $0.setting == setting && range.contains($0.audioSeconds) }
            print(String(
                format: "%@ | %@ | %d | %.2f | %.2f | %.2f | %.2f", setting, label, set.count, quantile(set.map(\.todayEstimate), 0.5),
                quantile(set.map(\.todayEstimate), 0.9), quantile(set.map(\.piecesEstimate), 0.5), quantile(set.map(\.piecesEstimate), 0.9)
            ))
        }
    }
}
