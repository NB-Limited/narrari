import Foundation
import Observation

// The models a meeting uses besides speech, downloaded by themselves when a meeting starts or a step needs one.
@MainActor
@Observable
public final class MeetingModels: MeetingModelSupply {
    public typealias Fetch = @Sendable (AudioModel, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void

    public enum Status: Sendable, Equatable {
        case notDownloaded
        case downloading(Double)
        case onThisMac(bytes: Int64)
        case failed(String)
    }

    public private(set) var statuses: [AudioModel: Status] = [:]

    @ObservationIgnored private let store: ModelStore
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let speech: SharedModel?
    @ObservationIgnored private let cleanup: SharedModel?
    @ObservationIgnored private var downloads: [AudioModel: Task<Void, Never>] = [:]
    @ObservationIgnored private var sharedDownloads: [NeededModel: Task<Bool, Never>] = [:]

    static let downloadFailed = "The download failed. Check the connection and try again."

    // Without the speech or clean-up model, a step waiting for it reads as needing it and waits until retried.
    public init(store: ModelStore, fetch: @escaping Fetch, speech: SharedModel? = nil, cleanup: SharedModel? = nil) {
        self.store = store
        self.fetch = fetch
        self.speech = speech
        self.cleanup = cleanup
        refresh()
    }

    public static var all: [AudioModel] { [.echoRemoval, .speechDetection, .speakerSplit] }

    public func status(of model: AudioModel) -> Status {
        statuses[model] ?? .notDownloaded
    }

    // The catalogue's measured size, so a row says what a download takes before it runs.
    public static func size(of model: AudioModel) -> Int64 {
        entry(model)?.metrics.diskBytes ?? 0
    }

    public static func plainName(of model: AudioModel) -> String {
        entry(model)?.plainName ?? model.name
    }

    public func detail(of model: AudioModel) -> String {
        let purpose = Self.entry(model)?.purpose.map { "\($0), " } ?? ""
        return switch status(of: model) {
        case .onThisMac(let bytes): "\(purpose)\(MetricText.bytes(bytes)), on this Mac"
        case .downloading(let fraction): "Downloading, \(MetricText.percent(fraction))"
        case .notDownloaded, .failed: "\(purpose)\(MetricText.bytes(Self.size(of: model)))"
        }
    }

    public func refresh() {
        for model in Self.all where downloads[model] == nil {
            let bytes = (try? store.bytesOnDisk(named: model.folder)) ?? 0
            statuses[model] = bytes > 0 ? .onThisMac(bytes: bytes) : .notDownloaded
        }
    }

    public func begin(_ models: [AudioModel]) {
        for model in models where downloads[model] == nil {
            if case .onThisMac = status(of: model) { continue }
            downloads[model] = start(model)
        }
    }

    public func status(of needed: NeededModel) -> Status {
        switch needed {
        case .meeting(let model): status(of: model)
        case .speech: speech?.status ?? .notDownloaded
        case .cleanup: cleanup?.status ?? .notDownloaded
        }
    }

    public func size(of needed: NeededModel) -> Int64 {
        switch needed {
        case .meeting(let model): Self.size(of: model)
        case .speech: speech?.size() ?? 0
        case .cleanup: cleanup?.size() ?? 0
        }
    }

    public func begin(_ needed: [NeededModel]) {
        begin(needed.compactMap { if case .meeting(let model) = $0 { model } else { nil } })
        for (model, shared) in shared(in: needed) where sharedDownloads[model] == nil {
            if case .onThisMac = shared.status { continue }
            sharedDownloads[model] = Task { [weak self] in
                let isDone = await shared.download()
                self?.sharedDownloads[model] = nil
                return isDone
            }
        }
    }

    public func download(_ needed: [NeededModel]) async -> Bool {
        begin(needed)
        var isDone = await download(needed.compactMap { if case .meeting(let model) = $0 { model } else { nil } })
        for (model, _) in shared(in: needed) {
            let landed = await sharedDownloads[model]?.value ?? isOnThisMac(model)
            isDone = landed && isDone
        }
        return isDone
    }

    // Each time a model a step may wait for lands, however it was downloaded, until the app quits.
    public func whenLanded(_ action: @escaping @MainActor () async -> Void) {
        let before = Set(NeededModel.all.filter(isOnThisMac))
        withObservationTracking {
            _ = NeededModel.all.map(self.status(of:))
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !Set(NeededModel.all.filter(self.isOnThisMac)).isSubset(of: before) { await action() }
                self.whenLanded(action)
            }
        }
    }

    @discardableResult
    public func download(_ models: [AudioModel]) async -> Bool {
        begin(models)
        for model in models {
            await downloads[model]?.value
        }
        return models.allSatisfy { if case .onThisMac = status(of: $0) { true } else { false } }
    }

    public func cancel(_ model: AudioModel) {
        downloads[model]?.cancel()
    }

    public func delete(_ model: AudioModel) {
        do {
            try store.delete(named: model.folder)
        } catch {
            Log.failure("meeting-model-delete", error: error)
        }
        refresh()
    }

    private func isOnThisMac(_ needed: NeededModel) -> Bool {
        if case .onThisMac = status(of: needed) { true } else { false }
    }

    private func shared(in needed: [NeededModel]) -> [(NeededModel, SharedModel)] {
        needed.compactMap { model in
            switch model {
            case .meeting: nil
            case .speech: speech.map { (model, $0) }
            case .cleanup: cleanup.map { (model, $0) }
            }
        }
    }

    private static func entry(_ model: AudioModel) -> CatalogueModel? {
        ModelCatalogue.meetings.first { $0.id == model.folder }
    }

    private func start(_ model: AudioModel) -> Task<Void, Never> {
        statuses[model] = .downloading(0)
        return Task { [weak self, store, fetch] in
            do {
                try await fetch(model) { fraction in
                    Task { @MainActor in self?.progress(model, fraction) }
                }
                try Task.checkCancellation()
                Log.event("meeting-model-downloaded")
            } catch is CancellationError {
                do {
                    try store.delete(named: model.folder)
                } catch {
                    Log.failure("meeting-model-cancel-delete", error: error)
                }
            } catch {
                Log.failure("meeting-model-download", error: error)
                self?.statuses[model] = .failed(Self.downloadFailed)
            }
            self?.downloads[model] = nil
            if case .failed = self?.statuses[model] { return }
            self?.refresh()
        }
    }

    private func progress(_ model: AudioModel, _ fraction: Double) {
        guard downloads[model] != nil else { return }
        statuses[model] = .downloading(fraction)
    }
}

// The speech or clean-up model as a meeting step waits for it: dictation shares it, and its settings page downloads it too.
@MainActor
public struct SharedModel {
    let size: @MainActor () -> Int64
    let state: @MainActor () -> ModelState
    let isOnThisMac: @MainActor () -> Bool
    // Starts the download, or joins the one under way; true once the model is on this Mac.
    let download: @MainActor () async -> Bool

    public init(
        size: @escaping @MainActor () -> Int64, state: @escaping @MainActor () -> ModelState, isOnThisMac: @escaping @MainActor () -> Bool,
        download: @escaping @MainActor () async -> Bool
    ) {
        self.size = size
        self.state = state
        self.isOnThisMac = isOnThisMac
        self.download = download
    }

    var status: MeetingModels.Status {
        if case .preparing(let fraction, isDownloading: true) = state() { return .downloading(fraction) }
        if isOnThisMac() { return .onThisMac(bytes: size()) }
        if case .failed = state() { return .failed(MeetingModels.downloadFailed) }
        return .notDownloaded
    }

    // The dictation transcriber downloads and loads it, so the next dictation finds it ready.
    public static func speech(_ transcriber: ParakeetTranscriber, status: ModelStatus, store: ModelStore, settings: SettingsStore) -> Self {
        let chosen = { settings.value(SpeechSettings.localModel) }
        return Self(
            size: { ModelCatalogue.speech.first { $0.id == chosen().folder }?.metrics.diskBytes ?? 0 },
            state: { status.state },
            isOnThisMac: { store.isPresent(named: chosen().folder) },
            download: { (try? await transcriber.load()) != nil }
        )
    }

    // The slot's own engine when it runs this model, so the download shows on the Clean-up page too; else one let go after.
    public static func cleanup(_ slot: CleanupEngineSlot, store: ModelStore) -> Self {
        Self(
            size: { ModelCatalogue.cleanup.first { ModelReference($0.id).id == slot.localModel.id }?.metrics.diskBytes ?? 0 },
            state: { slot.localStatus.state },
            isOnThisMac: { ModelHub(store: store).cachedModelIDs().contains(slot.localModel.id) },
            download: {
                let shared = slot.current as? LocalModelEngine
                let engine = shared?.name == slot.localModel.id ? shared : nil
                let own = engine ?? LocalModelEngine(model: slot.localModel, store: store, onStateChange: slot.localStatus.report)
                let isLoaded = (try? await own.load()) != nil
                if engine == nil { await own.unload() }
                return isLoaded
            }
        )
    }
}
