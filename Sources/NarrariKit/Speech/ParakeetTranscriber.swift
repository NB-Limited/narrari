import FluidAudio
import Foundation

// Runs the model the settings choose. A call after the choice changed lets the old model go and loads the new one.
public actor ParakeetTranscriber: Transcriber {
    public nonisolated var name: String { settings.value(SpeechSettings.localModel).name }

    private let store: ModelStore
    private let settings: SettingsStore
    private let downloadsIfMissing: Bool
    private let vocabulary: Vocabulary?
    private let onStateChange: @Sendable (ModelState) -> Void
    private var manager: AsrManager?
    private var loading: Task<AsrManager, any Error>?
    private var loadedModel: ParakeetModel?
    private var loadGeneration = 0

    // An instance that must never download, such as the live-text one, loads only from files already on disk.
    public init(
        store: ModelStore,
        settings: SettingsStore,
        downloadsIfMissing: Bool = true,
        vocabulary: Vocabulary? = nil,
        onStateChange: @escaping @Sendable (ModelState) -> Void = { _ in }
    ) {
        self.store = store
        self.settings = settings
        self.downloadsIfMissing = downloadsIfMissing
        self.vocabulary = vocabulary
        self.onStateChange = onStateChange
    }

    public func load() async throws {
        _ = try await loadedManager()
    }

    public func unload() async {
        loading?.cancel()
        loading = nil
        await manager?.cleanup()
        manager = nil
        onStateChange(.missing)
    }

    // The languages the speech model transcribes, which a meeting's language can be chosen from.
    public static let languages: [SpokenLanguage] = Language.allCases
        .map { SpokenLanguage(id: $0.rawValue, name: SpokenLanguage.name(of: $0.rawValue)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    // A piece of a file, with how far the model is through it.
    public func transcribe(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let manager = try await loadedManager()
        let updates = await manager.transcriptionProgressStream
        let reporting = Task {
            for try await fraction in updates { progress(fraction) }
        }
        defer { reporting.cancel() }
        return try await transcribe(samples: samples, with: manager)
    }

    public func transcribe(samples: [Float]) async throws -> Transcript {
        try await transcribe(samples: samples, with: try await loadedManager())
    }

    private func transcribe(samples: [Float], with manager: AsrManager) async throws -> Transcript {
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            var text = result.text
            var words = Self.words(from: result.tokenTimings ?? [])
            if let vocabulary, let timings = result.tokenTimings {
                let boosted = await vocabulary.boost(text, tokenTimings: timings, samples: samples)
                if boosted != text { words = Transcript.Word.respelled(words, as: boosted) }
                text = boosted
            }
            return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), audioSeconds: result.duration, words: words)
        } catch let error as CancellationError {
            throw error
        } catch {
            Log.failure("transcribe", error: error)
            throw TranscriberError.transcriptionFailed(reason: error.localizedDescription)
        }
    }

    // The model emits a closing punctuation mark when the next word starts, so the mark takes the time of the sound before
    // it; otherwise the pause after a sentence would hide inside the sentence's last word.
    private static func words(from tokens: [TokenTiming]) -> [Transcript.Word] {
        var heardUntil = 0.0
        let placed = tokens.map { token in
            guard !isWordBoundary(token.token), !token.token.contains(where: { $0.isLetter || $0.isNumber }) else {
                heardUntil = token.endTime
                return token
            }
            return TokenTiming(token: token.token, tokenId: token.tokenId, startTime: heardUntil, endTime: heardUntil, confidence: token.confidence)
        }
        return buildWordTimings(from: placed).map { Transcript.Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    // Waiting stops when the caller is cancelled; the load itself goes on, so the next dictation finds the model ready.
    // A cancelled caller never starts a load, so a pass that outlives an unload can't bring the model back.
    private func loadedManager() async throws -> AsrManager {
        let model = settings.value(SpeechSettings.localModel)
        if model != loadedModel { dropModel() }
        if let manager { return manager }
        if loading == nil { try Task.checkCancellation() }
        let load = loading ?? startLoading(model)
        return try await firstToFinish { try await load.value }
    }

    // Without waiting, so no other call can slip in between dropping the old model and loading the new one.
    private func dropModel() {
        loading?.cancel()
        loading = nil
        if let old = manager { Task { await old.cleanup() } }
        manager = nil
    }

    // The load records its own result, so every caller waiting on it gets the same answer.
    // A load cancelled by unload leaves the state unload set, and never clears a newer load that started since.
    private func startLoading(_ model: ParakeetModel) -> Task<AsrManager, any Error> {
        loadedModel = model
        let directory = store.directory(named: model.folder)
        let isPresent = downloadsIfMissing || store.isPresent(named: model.folder)
        let onStateChange = onStateChange
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task {
            defer { if loadGeneration == generation { loading = nil } }
            onStateChange(.preparing(fraction: 0))
            do {
                guard isPresent else { throw TranscriberError.notDownloaded }
                let models = try await AsrModels.downloadAndLoad(to: directory, version: model.version) { progress in
                    onStateChange(.preparing(fraction: progress.fractionCompleted, isDownloading: progress.isDownloading))
                }
                let loaded = AsrManager()
                try await loaded.loadModels(models)
                try Task.checkCancellation()
                manager = loaded
                onStateChange(.ready)
                return loaded
            } catch {
                if Task.isCancelled { throw CancellationError() }
                Log.failure("model-load", error: error)
                let reason = error.localizedDescription
                onStateChange(.failed(reason: reason))
                throw TranscriberError.modelUnavailable(reason: reason)
            }
        }
        loading = task
        return task
    }
}

extension DownloadProgress {
    var isDownloading: Bool {
        switch phase {
        case .listing, .downloading: true
        case .compiling: false
        }
    }
}
