import Foundation
import Observation

// Owns the speech models on this Mac: choose, download, cancel and delete. The live-text instance and the
// dictionary's small model go when live text goes off, the model changes or its files are deleted.
@MainActor
@Observable
public final class SpeechModelControl {
    public private(set) var chosen: ParakeetModel
    public private(set) var bytesOnDisk: [ParakeetModel: Int64] = [:]

    @ObservationIgnored private let local: ParakeetTranscriber
    @ObservationIgnored private let livePreview: LivePreview
    @ObservationIgnored private let status: ModelStatus
    @ObservationIgnored private let store: ModelStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let vocabulary: Vocabulary?
    @ObservationIgnored private let dictionary: DictionaryStore
    @ObservationIgnored private var following: Task<Void, Never>?

    public init(
        local: ParakeetTranscriber,
        livePreview: LivePreview,
        status: ModelStatus,
        store: ModelStore,
        settings: SettingsStore,
        vocabulary: Vocabulary? = nil,
        dictionary: DictionaryStore
    ) {
        self.local = local
        self.livePreview = livePreview
        self.status = status
        self.store = store
        self.settings = settings
        self.vocabulary = vocabulary
        self.dictionary = dictionary
        // Builds before the choice ran v3 only, so an install with v3 keeps it; a fresh one gets the recommended model.
        if !settings.hasValue(for: SpeechSettings.localModel) {
            let first: ParakeetModel = store.isPresent(named: ParakeetModel.v3.folder) ? .v3 : .recommended
            settings.set(first, for: SpeechSettings.localModel)
        }
        chosen = settings.value(SpeechSettings.localModel)
        let updates = SettingsChanges.updates(of: [DictationSettings.showsLiveText.key])
        following = Task {
            for await _ in updates where !settings.value(DictationSettings.showsLiveText) {
                await livePreview.release()
            }
        }
        SettingsChanges.follow([SpeechSettings.localModel.key], by: self) { control in
            let model = settings.value(SpeechSettings.localModel)
            if model != control.chosen { control.load(model) }
        }
    }

    isolated deinit {
        following?.cancel()
    }

    public var state: ModelState { status.state }

    public func start() {
        download()
    }

    // A failed load is logged and reported through the model state. Once loaded, the dictionary's words get ready too.
    public func download() {
        Task {
            if (try? await local.load()) != nil {
                await vocabulary?.prepare(from: dictionary)
            }
            refreshSize()
        }
    }

    public func use(_ model: ParakeetModel) {
        if model != chosen { settings.set(model, for: SpeechSettings.localModel) }
        load(model)
    }

    // The dictation instance swaps to the new model as it loads; the live-text one lets the old model go now.
    private func load(_ model: ParakeetModel) {
        if model != chosen {
            chosen = model
            Task { await livePreview.release() }
        }
        download()
    }

    // Only a download is cancelled, so its files are incomplete and go with it.
    @discardableResult
    public func cancel() -> Task<Void, Never> {
        let model = chosen
        return Task {
            await local.unload()
            await livePreview.release()
            do {
                try store.delete(named: model.folder)
            } catch {
                Log.failure("speech-model-cancel", error: error)
            }
            refreshSize()
        }
    }

    public func delete(_ model: ParakeetModel) async throws {
        defer { refreshSize() }
        if model == chosen {
            await local.unload()
            await livePreview.release()
            await vocabulary?.release()
            try store.delete(named: Vocabulary.modelName)
        }
        try store.delete(named: model.folder)
        Log.event("speech-model-deleted")
    }

    public func refreshSize() {
        for model in ParakeetModel.allCases {
            do {
                bytesOnDisk[model] = store.isPresent(model) ? try store.bytesOnDisk(named: model.folder) : 0
            } catch {
                Log.failure("speech-model-size", error: error)
            }
        }
    }
}
