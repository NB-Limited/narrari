import Foundation

public enum Retention {
    public static func run(
        on store: HistoryStore, settings: SettingsStore, now: Date, keeping kept: Set<UUID> = []
    ) async throws {
        let days = settings.value(HistorySettings.retentionDays)
        guard days > 0 else { return }
        try await store.removeDays(olderThan: days, now: now, keeping: kept)
    }
}

// Recovers history and meetings at launch, then applies retention to both once a day and again whenever the setting changes.
@MainActor
public final class RetentionSchedule {
    private let store: HistoryStore
    private let meetings: MeetingStore
    private let settings: SettingsStore
    private let activeDictation: @MainActor () -> UUID?
    private let onRemoved: @MainActor () async -> Void
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private var tasks: [Task<Void, Never>] = []

    private static let interval: Duration = .seconds(24 * 60 * 60)

    public init(
        store: HistoryStore,
        meetings: MeetingStore,
        settings: SettingsStore,
        activeDictation: @escaping @MainActor () -> UUID? = { nil },
        onRemoved: @escaping @MainActor () async -> Void = {},
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.meetings = meetings
        self.settings = settings
        self.activeDictation = activeDictation
        self.onRemoved = onRemoved
        self.clock = clock
        self.now = now
    }

    isolated deinit {
        tasks.forEach { $0.cancel() }
    }

    public func start() {
        let updates = SettingsChanges.updates(of: [HistorySettings.retentionDays.key, MeetingsSettings.audioRetentionDays.key])
        tasks = [
            Task { [weak self, store, clock] in
                do {
                    try await store.recover()
                } catch {
                    Log.failure("history-recover", error: error)
                }
                while !Task.isCancelled {
                    await self?.apply()
                    try? await clock.sleep(for: Self.interval)
                }
            },
            Task { [weak self] in
                for await _ in updates { await self?.apply() }
            }
        ]
    }

    private func apply() async {
        do {
            try await Retention.run(on: store, settings: settings, now: now(), keeping: Set([activeDictation()].compactMap { $0 }))
        } catch {
            Log.failure("history-retention", error: error)
        }
        do {
            try await MeetingRetention.run(on: meetings, settings: settings, now: now())
        } catch {
            Log.failure("meeting-retention", error: error)
        }
        await onRemoved()
    }
}
