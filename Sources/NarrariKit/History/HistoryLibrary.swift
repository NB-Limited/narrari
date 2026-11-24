import Foundation
import Observation

@MainActor
@Observable
public final class HistoryLibrary {
    public struct EntryWork: Sendable, Equatable {
        public let state: WorkState
        public let choice: CleanupChoice?

        public var label: String {
            guard let choice, state.activity != nil else { return state.label }
            return choice.runningLabel
        }
    }

    public nonisolated static let readFailed = Problem("history.unreadable", "The dictations could not be read. Try again.", canRetry: true)

    public private(set) var entries: [HistoryEntry] = [] {
        didSet { searchResults() }
    }
    public private(set) var skippedLines = 0
    // Loading until the first read ends, then idle, or failed while the history cannot be read.
    public private(set) var load = WorkState.working(.loading)
    public private(set) var work: [UUID: EntryWork] = [:]
    public var searchText = "" {
        didSet { if searchText != oldValue { searchResults() } }
    }
    public var selection: UUID? {
        didSet { if selection != oldValue { pendingDeletion = nil } }
    }
    // The entry waiting for the user to confirm its deletion.
    public var pendingDeletion: UUID?
    // A file being transcribed: listed first, whatever the search, until it is saved or given up.
    public private(set) var pending: HistoryEntry? {
        didSet { searchResults() }
    }
    // Searched once per change of the entries, the query or the pending file, never per redraw.
    public private(set) var results: [HistoryEntry] = []

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
            load = .idle
        } catch {
            Log.failure("history-read", error: error)
            load = .failed(error.problem(or: Self.readFailed))
        }
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
        work[entry.id]?.state.activity != nil
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
        work[entry.id] = EntryWork(state: .working(.transcribing), choice: nil)
        do {
            _ = try await retranscription.run(entry)
            work[entry.id] = nil
        } catch {
            Log.failure("history-retranscribe", error: error)
            work[entry.id] = EntryWork(state: .failed(error.problem(or: TranscriberError.transcriptionFailed.problem)), choice: nil)
        }
        await refresh()
    }

    public var cleanupChoices: [CleanupChoice] {
        retranscription.prompts().map(CleanupChoice.init) + [.asSpoken]
    }

    // True once the new text is saved; false when it failed, the problem in work, or another run was going.
    @discardableResult
    public func cleanUp(_ entry: HistoryEntry, with choice: CleanupChoice) async -> Bool {
        guard !isBusy(entry), !entry.rawText.isEmpty else { return false }
        work[entry.id] = EntryWork(state: .working(.cleaningUp), choice: choice)
        Log.event("cleanup-again")
        let isSaved: Bool
        do {
            _ = try await retranscription.cleanUp(entry, with: choice)
            Log.event("cleanup-again-done")
            work[entry.id] = nil
            isSaved = true
        } catch {
            Log.failure("cleanup-again-failed", error: error)
            let problem = error.problem(or: RetranscriptionError.cleanupNotRun(.engineFailed).problem)
            work[entry.id] = EntryWork(state: .failed(problem), choice: choice)
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

    private func searchResults() {
        let shown = pending.flatMap { pending in entries.contains { $0.id == pending.id } ? nil : [pending] } ?? []
        results = shown + HistorySearch.entries(entries, matching: searchText, apps: apps)
    }

    private func keepSelectionInResults() {
        let list = results
        if selection == nil || !list.contains(where: { $0.id == selection }) {
            selection = list.first?.id
        }
    }
}
