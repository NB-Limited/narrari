import AppKit
import Observation

// The History page: how long dictations and meeting audio are kept, what is stored, and deleting every dictation.
@MainActor
@Observable
public final class HistoryPageModel {
    public enum Kind: Sendable, Equatable {
        case dictations
        case meetingAudio
    }

    public struct PendingRetention: Sendable, Equatable {
        public let kind: Kind
        public let days: Int
        public let count: Int
    }

    private static let retentionChoices = [1, 3, 7, 14, 30, 90, 0]

    public var retentionDays: Int { settings[HistorySettings.retentionDays] }
    public var meetingAudioDays: Int { settings[MeetingsSettings.audioRetentionDays] }
    public private(set) var usage: HistoryStore.Usage?
    public private(set) var meetingUsage: MeetingStore.Usage?
    public private(set) var pendingRetention: PendingRetention?
    public private(set) var isDeleteAllPending = false
    public private(set) var error: String?

    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let meetings: MeetingStore
    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let onDeleted: @MainActor () async -> Void
    @ObservationIgnored private let activeDictation: @MainActor () -> UUID?
    @ObservationIgnored private let stopPlayback: @MainActor () -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var retentionRequests = 0

    public init(
        store: HistoryStore,
        meetings: MeetingStore,
        settings: SettingsMirror,
        now: @escaping () -> Date = Date.init,
        activeDictation: @escaping @MainActor () -> UUID? = { nil },
        stopPlayback: @escaping @MainActor () -> Void = {},
        onDeleted: @escaping @MainActor () async -> Void = {}
    ) {
        self.store = store
        self.meetings = meetings
        self.settings = settings
        self.now = now
        self.activeDictation = activeDictation
        self.stopPlayback = stopPlayback
        self.onDeleted = onDeleted
    }

    public var locationLine: String { Self.abbreviated(store.root) }
    public var meetingLocationLine: String { Self.abbreviated(meetings.root) }

    public func days(_ kind: Kind) -> Int {
        kind == .dictations ? retentionDays : meetingAudioDays
    }

    public func retentionOptions(_ kind: Kind) -> [Int] {
        // 0 keeps forever, so it stays last.
        Self.retentionChoices.including(days(kind)) { $1 == 0 || $0 < $1 }
    }

    public static func title(forDays days: Int) -> String {
        switch days {
        case 0: "Keep forever"
        case 1: "1 day"
        default: "\(days) days"
        }
    }

    public var usageLine: String {
        guard let usage else { return "Counting…" }
        let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
        return "\(Self.count(usage.dictations, "dictation")), \(size) with their audio"
    }

    public var meetingUsageLine: String {
        guard let meetingUsage else { return "Counting…" }
        let size = ByteCountFormatter.string(fromByteCount: meetingUsage.bytes, countStyle: .file)
        return "\(Self.count(meetingUsage.meetings, "meeting")), \(size)"
    }

    public func retentionDetail(_ kind: Kind) -> String? {
        guard pendingRetention?.kind != kind else { return nil }
        guard days(kind) > 0 else { return "Nothing is deleted." }
        return kind == .dictations ? "Older ones are deleted daily." : "Older audio is deleted daily. Text stays."
    }

    public func pendingRetentionMessage(_ kind: Kind) -> String? {
        guard let pending = pendingRetention, pending.kind == kind else { return nil }
        let days = Self.title(forDays: pending.days)
        return switch kind {
        case .dictations: "Keeping \(days) deletes \(Self.count(pending.count, "dictation")) older than that now, with their audio."
        case .meetingAudio: "Keeping \(days) deletes the audio of \(Self.count(pending.count, "meeting")) older than that now. Their text stays."
        }
    }

    public var deleteAllMessage: String? {
        guard isDeleteAllPending, let usage else { return nil }
        return usage.dictations == 1
            ? "Delete the one dictation and its audio? This can't be undone."
            : "Delete all \(usage.dictations) dictations and their audio? This can't be undone."
    }

    // For the empty history page: how long a new dictation stays.
    public var keptLine: String {
        retentionDays > 0 ? "for \(retentionDays) \(retentionDays == 1 ? "day" : "days")" : "until you delete it"
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    public func appear() async {
        do {
            usage = try await store.usage()
            meetingUsage = try await meetings.usage()
        } catch {
            Log.failure("history-usage", error: error)
            self.error = "The history or meetings folder could not be read. Check that both still exist and can be opened."
        }
    }

    // A shorter time removes older dictations or meeting audio at once, so it asks first when there is any.
    public func requestRetention(_ days: Int, for kind: Kind) async {
        retentionRequests += 1
        let request = retentionRequests
        let current = self.days(kind)
        guard days != current else { return }
        pendingRetention = nil
        let shortens = days > 0 && (current == 0 || days < current)
        guard shortens else { return apply(days, for: kind) }
        do {
            let older = switch kind {
            case .dictations: try await store.dictations(olderThan: days, now: now())
            case .meetingAudio: try await MeetingRetention.meetings(olderThan: days, in: meetings, now: now())
            }
            // A choice made while this one counted is the one that stands.
            guard request == retentionRequests else { return }
            guard older > 0 else { return apply(days, for: kind) }
            pendingRetention = PendingRetention(kind: kind, days: days, count: older)
        } catch {
            Log.failure("history-count", error: error)
            guard request == retentionRequests else { return }
            self.error = "The folder could not be read, so the time was not changed. Try again."
        }
    }

    public func confirmRetention() async {
        guard let pending = pendingRetention else { return }
        pendingRetention = nil
        stopPlayback()
        apply(pending.days, for: pending.kind)
        // Retention follows the setting on its own; this waits for it so the count below is current.
        do {
            switch pending.kind {
            case .dictations: try await Retention.run(on: store, settings: settings.store, now: now(), keeping: kept)
            case .meetingAudio: try await MeetingRetention.run(on: meetings, settings: settings.store, now: now())
            }
        } catch {
            Log.failure("history-retention-confirm", error: error)
        }
        await onDeleted()
        await appear()
    }

    public func cancelRetention() {
        pendingRetention = nil
    }

    public func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.root])
    }

    public func showMeetingsInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([meetings.root])
    }

    public func requestDeleteAll() {
        isDeleteAllPending = true
    }

    public func cancelDeleteAll() {
        isDeleteAllPending = false
    }

    public func confirmDeleteAll() async {
        isDeleteAllPending = false
        stopPlayback()
        do {
            try await store.deleteAll(keeping: kept)
            error = nil
        } catch {
            Log.failure("history-delete-all", error: error)
            self.error = "Some dictations could not be deleted. Open the folder in Finder to check, then try again."
        }
        await onDeleted()
        await appear()
    }

    // A dictation still recording keeps its audio and lines, whatever is deleted around it.
    private var kept: Set<UUID> { Set([activeDictation()].compactMap { $0 }) }

    private func apply(_ days: Int, for kind: Kind) {
        switch kind {
        case .dictations:
            settings[HistorySettings.retentionDays] = days
        case .meetingAudio:
            settings[MeetingsSettings.audioRetentionDays] = days
        }
        error = nil
    }
}
