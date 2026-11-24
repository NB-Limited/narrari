import Foundation
import Observation
import Synchronization

// Holds the clean-up engine the settings choose and swaps it when they change, so no relaunch is needed.
// The in-app model is let go once no dictation has used it for the idle limit, and loads again when the next one starts.
@MainActor
@Observable
public final class CleanupEngineSlot {
    public let localStatus = ModelStatus()

    private nonisolated let engine = Mutex<(any CleanupEngine)?>(nil)
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let keychain: any KeyStoring
    @ObservationIgnored private let store: ModelStore
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let choose: @MainActor (_ report: @escaping @Sendable (ModelState) -> Void) -> (any CleanupEngine)?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var isResting = false
    @ObservationIgnored private var idleUnload: Task<Void, Never>?

    private static let followedKeys: Set<String> = [
        CleanupSettings.engine.key, CleanupSettings.localModel.key, CleanupSettings.chatAddress.key,
        CleanupSettings.chatModel.key, CleanupSettings.chatKeyAccount
    ]

    public init(
        settings: SettingsStore,
        keychain: any KeyStoring,
        store: ModelStore,
        clock: any Clock<Duration> = ContinuousClock(),
        choose: (@MainActor (_ report: @escaping @Sendable (ModelState) -> Void) -> (any CleanupEngine)?)? = nil
    ) {
        self.settings = settings
        self.keychain = keychain
        self.store = store
        self.clock = clock
        self.choose = choose ?? { report in
            CleanupEngines.selected(settings: settings, keychain: keychain, store: store, onStateChange: report)
        }
    }

    public nonisolated var current: (any CleanupEngine)? { engine.withLock { $0 } }

    public var localModel: ModelReference { ModelReference(settings.value(CleanupSettings.localModel)) }

    // Until the first load finishes, which on first run includes the download, dictations paste the raw transcript.
    public func start() {
        reload()
        let updates = SettingsChanges.updates(of: Self.followedKeys)
        following = Task { [weak self] in
            for await _ in updates { self?.reload() }
        }
    }

    public func reload() {
        let next = choose(localStatus.report)
        // Typing a chat address must not reload the in-app model that is in use.
        if let old = current as? LocalModelEngine, let new = next as? LocalModelEngine, old.name == new.name { return }
        let previous = engine.withLock { slot in
            defer { slot = next }
            return slot
        }
        stopIdleUnload()
        Task { [weak self] in
            await previous?.unload()
            try? await next?.load()
            self?.unloadWhenIdle()
        }
    }

    // A dictation or a re-run starts: a model let go for being idle loads again while the user speaks.
    public func hold() {
        holders += 1
        let unloading = idleUnload
        let wasResting = isResting
        stopIdleUnload()
        guard wasResting, let current else { return }
        Task {
            await unloading?.value
            try? await current.load()
        }
    }

    public func release() {
        holders = max(holders - 1, 0)
        unloadWhenIdle()
    }

    // A load still running, a first download for one, is never cut off; its end starts the wait again.
    private func unloadWhenIdle() {
        guard holders == 0, let current, current.runsInApp else { return }
        idleUnload?.cancel()
        let limit = Duration.seconds(settings.value(CleanupSettings.idleLimit))
        idleUnload = Task { [weak self, clock] in
            guard (try? await clock.sleep(for: limit)) != nil, await current.state == .ready, !Task.isCancelled,
                  let self
            else { return }
            isResting = true
            await current.unload()
        }
    }

    private func stopIdleUnload() {
        idleUnload?.cancel()
        idleUnload = nil
        isResting = false
    }

    public func loadLocal() {
        guard let local = current as? LocalModelEngine else { return }
        stopIdleUnload()
        Task { [weak self] in
            try? await local.load()
            self?.unloadWhenIdle()
        }
    }

    // Only a download is cancelled, so its files are incomplete; they go with it, or the model would read as on this Mac.
    public func cancelLocal() async {
        guard let local = current as? LocalModelEngine else { return }
        stopIdleUnload()
        do {
            try await local.delete()
        } catch {
            Log.failure("cleanup-model-cancel", error: error)
        }
    }

    public func deleteLocal() async throws {
        stopIdleUnload()
        let local = current as? LocalModelEngine ?? LocalModelEngine(model: localModel, store: store)
        try await local.delete()
        Log.event("cleanup-model-deleted")
    }

    public func localBytesOnDisk() throws -> Int64 {
        try LocalModelEngine(model: localModel, store: store).bytesOnDisk()
    }

    // Clean-up models downloaded before, such as an earlier choice, other than the one set to be used.
    public func otherLocalModels() -> [CachedModel] {
        ModelHub(store: store).cachedModelIDs().filter { $0 != localModel.id }.map { id in
            let bytes: Int64
            do {
                bytes = try LocalModelEngine(model: ModelReference(id), store: store).bytesOnDisk()
            } catch {
                Log.failure("cleanup-other-model-size", error: error)
                bytes = 0
            }
            return CachedModel(id: id, bytesOnDisk: bytes)
        }
    }

    public func deleteOther(_ id: String) async throws {
        guard id != localModel.id, ModelHub(store: store).cachedModelIDs().contains(id) else { return }
        try await LocalModelEngine(model: ModelReference(id), store: store).delete()
        Log.event("cleanup-other-model-deleted")
    }
}

public struct CachedModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let bytesOnDisk: Int64

    public var displayName: String { ModelReference(id).displayName }
}
