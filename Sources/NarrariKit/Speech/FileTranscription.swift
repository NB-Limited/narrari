import Foundation

public struct FileTranscription: Sendable {
    // The window shows whole percents, so only a fraction that moves to a new one is passed on.
    public struct Steps: Sendable {
        private var last: Int?

        public init() {}

        public mutating func admit(_ fraction: Double) -> Bool {
            let percent = Int(fraction * 100)
            guard percent != last else { return false }
            last = percent
            return true
        }
    }

    private let store: ModelStore
    private let settings: SettingsStore
    private let dictionary: DictionaryStore

    public init(store: ModelStore, settings: SettingsStore, dictionary: DictionaryStore) {
        self.store = store
        self.settings = settings
        self.dictionary = dictionary
    }

    public var modelName: String { settings.value(SpeechSettings.localModel).name }

    // Piece by piece, so length is no limit; `limit` refuses a longer file, and nil takes any length.
    // With a place to keep the audio, a transcribed file's audio is written there the way a dictation's is.
    public func run(
        _ url: URL, keepingAudioAt kept: URL? = nil, upTo limit: TimeInterval? = AudioFileDecoder.maximumDuration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        guard store.isPresent(named: settings.value(SpeechSettings.localModel).folder) else {
            throw TranscriberError.notDownloaded
        }
        let pieces = try await SpeechPieces(url: url, upTo: limit)
        let keeper = try kept.map { try TrackWriter(writingTo: $0, sourceRate: SpeechAudio.sampleRate) }
        // Its own models, loaded from disk for this job and dropped after, so a dictation never waits behind it.
        let vocabulary = Vocabulary(store: store, settings: settings)
        await vocabulary.prepare(from: dictionary)
        let model = ParakeetTranscriber(store: store, settings: settings, vocabulary: vocabulary)
        let duration = max(pieces.duration, 1)
        do {
            var heard = Heard()
            while let piece = try pieces.next() {
                try Task.checkCancellation()
                piece.samples.withUnsafeBufferPointer { keeper?.append($0, at: piece.start) }
                let share: @Sendable (Double) -> Void = { fraction in
                    progress(min((piece.start + fraction * (piece.end - piece.start)) / duration, 1))
                }
                if piece.samples.count >= SpeechAudio.minimumSamples {
                    heard.add(try await model.transcribe(samples: piece.samples, progress: share), at: piece.start)
                }
                heard.seconds = piece.end
                share(1)
            }
            keeper?.finish(at: heard.seconds)
            await model.unload()
            return heard.transcript
        } catch {
            await model.unload()
            throw error
        }
    }

    private struct Heard {
        var texts: [String] = []
        var words: [Transcript.Word] = []
        var seconds = 0.0

        mutating func add(_ piece: Transcript, at start: Double) {
            if !piece.text.isEmpty { texts.append(piece.text) }
            words += piece.words.map { Transcript.Word(text: $0.text, start: $0.start + start, end: $0.end + start) }
        }

        var transcript: Transcript { Transcript(text: texts.joined(separator: " "), audioSeconds: seconds, words: words) }
    }
}
