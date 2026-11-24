import Foundation
import Observation

@MainActor
@Observable
public final class HistoryLibrary {
    public private(set) var entries: [HistoryEntry] = []
    public private(set) var skippedLines = 0
    public private(set) var hasLoaded = false
    public private(set) var retranscribing: Set<UUID> = []
    public private(set) var cleaningUp: [UUID: CleanupChoice] = [:]
    public private(set) var errors: [UUID: String] = [:]
    public var searchText = ""
    public var selection: UUID? {
        didSet { if selection != oldValue { pendingDeletion = nil } }
    }
    // The entry waiting for the user to confirm its deletion.
    public var pendingDeletion: UUID?
    // A file being transcribed: listed first, whatever the search, until it is saved or given up.
    public private(set) var pending: HistoryEntry?

    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let retranscription: Retranscription
    @ObservationIgnored public let apps: AppDirectory
    @ObservationIgnored private let activeDictation: @MainActor () -> UUID?
    @ObservationIgnored private let now: () -> Date

    public init(
        store: HistoryStore,
        retranscription: Retranscription,
        apps: AppDirectory,
        activeDictation: @escaping @MainActor () -> UUID? = { nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.retranscription = retranscription
        self.apps = apps
        self.activeDictation = activeDictation
        self.now = now
    }

    public var results: [HistoryEntry] {
        let shown = pending.flatMap { pending in entries.contains { $0.id == pending.id } ? nil : [pending] } ?? []
        return shown + HistorySearch.entries(entries, matching: searchText, apps: apps)
    }

    public var days: [HistoryDay] { HistoryDay.group(results, now: now()) }

    public var selected: HistoryEntry? {
        guard let selection else { return nil }
        return results.first { $0.id == selection }
    }

    public var lastDictation: HistoryEntry? { entries.first { !$0.finalText.isEmpty } }

    public func hasAudio(_ entry: HistoryEntry) -> Bool {
        FileManager.default.fileExists(atPath: store.audioURL(for: entry.id).path)
    }

    public func audioURL(for entry: HistoryEntry) -> URL {
        store.audioURL(for: entry.id)
    }

    public func refresh() async {
        do {
            let read = try await store.entries()
            entries = read.entries.filter(\.isFinished)
            skippedLines = read.skipped
        } catch {
            Log.failure("history-read", error: error)
        }
        hasLoaded = true
        keepSelectionInResults()
    }

    public func follow(_ changes: AsyncStream<Void>) async {
        for await _ in changes { await refresh() }
    }

    public func moveSelection(by offset: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selection }.map { $0 + offset } ?? 0
        selection = list[min(max(index, 0), list.count - 1)].id
    }

    public func searchChanged() {
        keepSelectionInResults()
    }

    // Transcribed or cleaned up again: one at a time, so neither result overwrites the other.
    public func isBusy(_ entry: HistoryEntry) -> Bool {
        retranscribing.contains(entry.id) || cleaningUp[entry.id] != nil
    }

    // Not while it is worked on again, whose result would land on a deleted entry, nor while it is still recording.
    public func canDelete(_ entry: HistoryEntry) -> Bool {
        !isBusy(entry) && entry.id != activeDictation() && entry.id != pending?.id
    }

    public func delete(_ entry: HistoryEntry) async {
        guard canDelete(entry) else { return }
        let list = results
        if selection == entry.id, let index = list.firstIndex(where: { $0.id == entry.id }) {
            let neighbour = list.indices.contains(index + 1) ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
            selection = neighbour?.id
        }
        do {
            try await store.delete(entry)
            Log.event("history-entry-deleted")
        } catch {
            Log.failure("history-delete", error: error)
        }
        await refresh()
    }

    public func retranscribe(_ entry: HistoryEntry) async {
        guard !isBusy(entry) else { return }
        retranscribing.insert(entry.id)
        errors[entry.id] = nil
        defer { retranscribing.remove(entry.id) }
        do {
            _ = try await retranscription.run(entry)
        } catch {
            Log.failure("history-retranscribe", error: error)
            errors[entry.id] = Self.message(for: error)
        }
        await refresh()
    }

    public var cleanupChoices: [CleanupChoice] {
        retranscription.prompts().map(CleanupChoice.init) + [.asSpoken]
    }

    // True once the new text is saved; false when it failed, the reason in errors, or another run was going.
    @discardableResult
    public func cleanUp(_ entry: HistoryEntry, with choice: CleanupChoice) async -> Bool {
        guard !isBusy(entry), !entry.rawText.isEmpty else { return false }
        cleaningUp[entry.id] = choice
        errors[entry.id] = nil
        defer { cleaningUp[entry.id] = nil }
        Log.event("cleanup-again")
        let isSaved: Bool
        do {
            _ = try await retranscription.cleanUp(entry, with: choice)
            Log.event("cleanup-again-done")
            isSaved = true
        } catch {
            Log.failure("cleanup-again-failed", error: error)
            errors[entry.id] = Self.cleanupMessage(for: error)
            isSaved = false
        }
        await refresh()
        return isSaved
    }

    func show(pending entry: HistoryEntry) {
        pending = entry
        selection = entry.id
    }

    func endPending() {
        pending = nil
        keepSelectionInResults()
    }

    private func keepSelectionInResults() {
        let list = results
        if selection == nil || !list.contains(where: { $0.id == selection }) {
            selection = list.first?.id
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case RetranscriptionError.audioMissing: "The audio of this dictation is gone, so it can't be transcribed again."
        case RetranscriptionError.nothingHeard: "Nothing heard in the audio. The dictation is unchanged."
        case HistoryError.entryGone: "This dictation was deleted, so the new text was not kept."
        case TranscriberError.modelUnavailable: "The speech model is not available. The audio is kept; try again once it has loaded."
        default: "Transcription failed. The audio is kept; try again."
        }
    }

    private static func cleanupMessage(for error: any Error) -> String {
        switch error {
        case HistoryError.entryGone: message(for: error)
        case RetranscriptionError.cleanupNotRun(let reason): Notice.cleanupReason(reason) + " The text is unchanged."
        default: Notice.cleanupReason(.engineFailed) + " The text is unchanged."
        }
    }
}
