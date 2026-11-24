import FluidAudio
import Foundation

public enum VocabularyError: ProblemError {
    case notReady

    public var problem: Problem {
        Problem("vocabulary.not-ready", "Could not get ready for these words. Clean-up still sees them.", canRetry: true)
    }
}

public actor Vocabulary {
    public static let modelName = CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent

    // FluidAudio's acoustic rescue replaces spans spelled nothing like a term, such as "4,200 euros" with a surname.
    private static let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
    // Measured on spoken clips: 1.5 recovers misheard terms that 0 misses; "twist" became "Tuist" from about 3.
    private static let thresholds = VocabularyBoostingSession.Thresholds(cbw: 1.5, minSimilarity: 0.7)

    private let store: ModelStore
    private let settings: SettingsStore
    private let onStateChange: @Sendable (ModelState) -> Void
    private var words: [String] = []
    private var session: VocabularyBoostingSession?
    private var isLoading = false
    private var following: Task<Void, Never>?

    public init(
        store: ModelStore,
        settings: SettingsStore,
        onStateChange: @escaping @Sendable (ModelState) -> Void = { _ in }
    ) {
        self.store = store
        self.settings = settings
        self.onStateChange = onStateChange
    }

    deinit {
        following?.cancel()
    }

    // Prepares now and again after every save of the word list.
    public func follow(_ dictionary: DictionaryStore) async {
        let updates = SettingsChanges.updates(of: [DictionaryStore.changeKey])
        following?.cancel()
        following = Task { [weak self] in
            for await _ in updates { await self?.prepare(from: dictionary) }
        }
        await prepare(from: dictionary)
    }

    public func prepare(from dictionary: DictionaryStore) async {
        do {
            await prepare(words: try dictionary.load().words)
        } catch {
            Log.failure("dictionary-load-vocabulary", error: error)
        }
    }

    public func prepare(words: [String]) async {
        let words = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // It listens alongside the speech model, so it waits until that model is on this Mac.
        guard store.isPresent(named: settings.value(SpeechSettings.localModel).folder) else { return release() }
        // A save that leaves the words alone, such as a new replacement, keeps the session or the load in progress.
        guard words != self.words || (session == nil && !isLoading) else { return }
        self.words = words
        session = nil
        isLoading = false
        guard !words.isEmpty else { return onStateChange(.missing) }
        onStateChange(.preparing(fraction: 0))
        isLoading = true
        defer { if self.words == words { isLoading = false } }
        do {
            let models = try await CtcModels.load(
                from: store.directory(named: Self.modelName), variant: .ctc110m
            ) { [onStateChange] progress in
                onStateChange(.preparing(fraction: progress.fractionCompleted, isDownloading: progress.isDownloading))
            }
            let vocabulary = CustomVocabularyContext(terms: words.map { CustomVocabularyTerm(text: $0) })
            let prepared = try await VocabularyBoostingSession(
                vocabulary: vocabulary, ctcModels: models, config: Self.config, thresholds: Self.thresholds
            )
            // The list may have changed while the encoder loaded; the newer call owns the session then.
            guard self.words == words else { return }
            session = prepared
            onStateChange(.ready)
            Log.event("vocabulary-ready")
        } catch {
            guard self.words == words else { return }
            Log.failure("vocabulary-load", error: error)
            onStateChange(.failed(VocabularyError.notReady.problem))
        }
    }

    // Forgets the words and the session, so the next prepare starts over.
    public func release() {
        words = []
        session = nil
        isLoading = false
        onStateChange(.missing)
    }

    func boost(_ text: String, tokenTimings: [TokenTiming], samples: [Float]) async -> String {
        guard let session, session.hasCTCRescoringCandidates(text: text, tokenTimings: tokenTimings) else { return text }
        guard let output = await session.rescore(text: text, tokenTimings: tokenTimings, audioSamples: samples),
              output.wasModified
        else { return text }
        Log.event("vocabulary-applied")
        return output.text
    }
}

extension Transcript.Word {
    // The words a boost changed take the time of the words they replace; the rest keep theirs.
    public static func respelled(_ words: [Self], as text: String) -> [Self] {
        let before = words.map(\.text)
        let after = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Self] = []
        var old = 0
        var new = 0
        while old < words.count || new < after.count {
            guard removed.contains(old) || inserted.contains(new) else {
                result.append(words[old])
                (old, new) = (old + 1, new + 1)
                continue
            }
            let first = old
            while old < words.count, removed.contains(old) { old += 1 }
            var typed: [String] = []
            while new < after.count, inserted.contains(new) {
                typed.append(after[new])
                new += 1
            }
            let start = old > first ? words[first].start : result.last?.end ?? 0
            let span = (old > first ? words[old - 1].end - start : 0) / Double(max(typed.count, 1))
            result += typed.enumerated().map { Self(text: $1, start: start + Double($0) * span, end: start + Double($0 + 1) * span) }
        }
        return result
    }
}
