import Foundation
import Observation

// The meetings side of the main window: the list by folder, search, the selection and what can be done to a meeting.
@MainActor
@Observable
public final class MeetingLibrary {
    public enum Entry: Identifiable, Sendable, Equatable {
        case meeting(Meeting, folder: String)
        // A folder whose meeting.json can't be read; it is listed and never changed.
        case unreadable(URL)

        public var id: EntryID {
            switch self {
            case .meeting(let meeting, _): .meeting(meeting.id)
            case .unreadable(let folder): .unreadable(folder)
            }
        }

        public var folder: String {
            switch self {
            case .meeting(_, let folder): folder
            case .unreadable(let url): url.deletingLastPathComponent().lastPathComponent
            }
        }

        var isPinned: Bool {
            if case .meeting(let meeting, _) = self { return meeting.pinned }
            return false
        }

        var date: Date {
            switch self {
            case .meeting(let meeting, _): meeting.startedAt
            case .unreadable(let url): MeetingFormat.folderDate(url) ?? .distantPast
            }
        }
    }

    public enum EntryID: Hashable, Sendable {
        case meeting(UUID)
        case unreadable(URL)
    }

    public struct Group: Identifiable, Sendable, Equatable {
        public let name: String
        public let entries: [Entry]
        public var id: String { name }
    }

    public enum RowState: Sendable, Equatable {
        case recording
        case work(WorkState)
    }

    public private(set) var entries: [Entry] = [] {
        didSet { noteLanded(after: oldValue) }
    }
    // Meetings whose processing or import ended with nothing failed, oldest first; only ever grows, so no end is missed.
    public private(set) var landed: [UUID] = []
    // Loading until the first read ends, then idle, or failed while the meetings cannot be read.
    public private(set) var load = WorkState.working(.loading)
    // Search results with where each hit; nil while the field is empty.
    public private(set) var hits: [MeetingSearch.Hit]?
    public private(set) var closedFolders: Set<String> = []
    public private(set) var importError: String?
    public var searchText = ""
    public var selection: EntryID? {
        didSet { if selection != oldValue { pendingDeletion = nil } }
    }
    public var pendingDeletion: UUID?
    // What ⌘C in the list copies: the shown meeting's tab text, set by its page.
    public var shownText: (meeting: UUID, text: String)?

    @ObservationIgnored public let store: MeetingStore
    @ObservationIgnored private let processor: any MeetingProcessor
    @ObservationIgnored private let models: MeetingModels
    @ObservationIgnored private let progress: MeetingTranscript.Progress
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let recording: @MainActor () -> UUID?
    @ObservationIgnored private let now: () -> Date

    public init(
        store: MeetingStore, processor: any MeetingProcessor, models: MeetingModels, progress: MeetingTranscript.Progress,
        settings: SettingsStore, recording: @escaping @MainActor () -> UUID?, now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.processor = processor
        self.models = models
        self.progress = progress
        self.settings = settings
        self.recording = recording
        self.now = now
    }

    // Folders in the order of their newest meeting; inside, pinned meetings first, each part newest first. An unreadable
    // folder goes by the date in its name.
    public var groups: [Group] {
        var order: [String] = []
        var byFolder: [String: [Entry]] = [:]
        for entry in entries.sorted(by: Self.newestFirst) {
            if byFolder[entry.folder] == nil { order.append(entry.folder) }
            byFolder[entry.folder, default: []].append(entry)
        }
        return order.map { name in
            let inside = byFolder[name] ?? []
            return Group(name: name, entries: inside.filter(\.isPinned) + inside.filter { !$0.isPinned })
        }
    }

    // What the list shows: the hits while searching, else every open folder's entries.
    public var visible: [Entry] {
        if let hits { return hits.map { .meeting($0.meeting, folder: folderName(of: $0.meeting.id)) } }
        return groups.filter { !closedFolders.contains($0.name) }.flatMap(\.entries)
    }

    public var copyText: String? {
        guard let shownText, selection == .meeting(shownText.meeting), !shownText.text.isEmpty else { return nil }
        return shownText.text
    }

    public var selected: Entry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    public var folders: [String] { groups.map(\.name) }

    public var retentionDays: Int { settings.value(MeetingsSettings.audioRetentionDays) }

    public func excerpt(of id: UUID) -> String? {
        hits?.first { $0.meeting.id == id }?.excerpt
    }

    public func state(of meeting: Meeting) -> RowState? {
        if meeting.id == recording() { return .recording }
        // Its stop could not be written; the next launch recovers it.
        if meeting.state == .recording { return .work(.failed(MeetingSession.couldNotSave)) }
        if meeting.state == .importing { return .work(.working(.importing)) }
        let steps = MeetingProcessing.Step.allCases.map { ($0, meeting.steps[$0]) }
        if let (step, running) = steps.first(where: { $0.1.status == .running }) {
            let fraction = step == .transcript ? progress.fractions[meeting.id] : nil
            return .work(.working(MeetingPage.activity(step), progress: fraction, since: running.since))
        }
        if let failed = steps.first(where: { $0.1.status == .failed }) { return .work(.failed(failed.0.problem(failed.1.problem))) }
        let needed = steps.filter { $0.1.status == .waiting }.flatMap { $0.1.waiting?.models ?? [] }.map(models.status(of:))
        if let failed = needed.lazy.compactMap({ if case .failed(let problem) = $0 { problem } else { nil } }).first { return .work(.failed(failed)) }
        if needed.contains(where: { if case .downloading = $0 { true } else { false } }) { return .work(.working(.downloading)) }
        guard meeting.state != .recording, steps.contains(where: { $0.1.status != .done }) else { return nil }
        return .work(.waiting(steps.lazy.compactMap { $0.1.status == .waiting ? $0.1.waiting : nil }.first ?? .turn))
    }

    public func refresh() async {
        do {
            let listed = try await store.list()
            entries = listed.meetings.map { .meeting($0.meeting, folder: $0.folder) } + listed.unreadable.map(Entry.unreadable)
            load = .idle
        } catch {
            Log.failure("meetings-read", error: error)
            load = .failed(error.problem(or: Self.readFailed))
        }
        if hits != nil { await search() }
        keepSelection()
    }

    public func follow() async {
        for await _ in store.changes { await refresh() }
    }

    // How long typing pauses before the search runs, so a burst of keys starts one search, not one per key.
    private static let typingPause = Duration.milliseconds(150)

    // From the search field, once per change of its text; a newer change cancels this one.
    public func searchTyped() async {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard (try? await Task.sleep(for: Self.typingPause)) != nil else { return }
        }
        await search()
    }

    public func search() async {
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = nil
            return keepSelection()
        }
        do {
            let found = try await MeetingSearch.hits(matching: query, in: store)
            guard query == searchText else { return }
            hits = found
        } catch is CancellationError {
            return
        } catch {
            Log.failure("meetings-search", error: error)
        }
        keepSelection()
    }

    public func toggleFolder(_ name: String) {
        if closedFolders.remove(name) == nil { closedFolders.insert(name) }
    }

    public func moveSelection(by offset: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selection }.map { $0 + offset } ?? 0
        selection = list[min(max(index, 0), list.count - 1)].id
    }

    public func rename(_ id: UUID, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await change(id) { meeting in
            guard meeting.title != title else { return }
            meeting.title = title
            meeting.titleIsMade = false
        }
    }

    public func togglePin(_ id: UUID) async {
        await change(id) { $0.pinned.toggle() }
    }

    public func move(_ id: UUID, toFolder name: String) async {
        do {
            try await store.move(id, toFolder: name)
        } catch {
            Log.failure("meeting-move", error: error)
        }
        await refresh()
    }

    // Not the one recording, whose files are still being written.
    public func canDelete(_ id: UUID) -> Bool {
        id != recording()
    }

    public func delete(_ id: UUID) async {
        guard canDelete(id) else { return }
        let list = visible
        if selection == .meeting(id), let index = list.firstIndex(where: { $0.id == .meeting(id) }) {
            selection = (list.indices.contains(index + 1) ? list[index + 1] : index > 0 ? list[index - 1] : nil)?.id
        }
        pendingDeletion = nil
        do {
            try await store.delete(id)
            Log.event("meeting-deleted")
        } catch {
            Log.failure("meeting-delete", error: error)
        }
        await refresh()
    }

    // Each recording, in turn, becomes the microphone track of a new meeting in Imported, dated when it was recorded, and its steps start.
    public func importRecordings(_ urls: [URL]) async {
        importError = nil
        Task { [processor] in await processor.prepare() }
        for url in urls { await importRecording(url) }
    }

    private func importRecording(_ url: URL) async {
        let meeting = Meeting(
            title: url.deletingPathExtension().lastPathComponent, startedAt: await AudioFileDecoder.recordingDate(of: url) ?? now(), app: "",
            source: .import, template: settings.value(MeetingsSettings.summaryTemplate), state: .importing
        )
        do {
            try await store.create(meeting, appName: "")
            await refresh()
            selection = .meeting(meeting.id)
            do {
                let seconds = try await AudioFileDecoder.writeTrack(from: url, to: try await store.audio(.microphone, of: meeting.id))
                try await store.update(meeting.id) { meeting in
                    meeting.durationMs = Int(seconds * 1000)
                    meeting.state = .ready
                }
            } catch {
                do {
                    try await store.delete(meeting.id)
                } catch {
                    Log.failure("meeting-import-discard", error: error)
                }
                throw error
            }
            Log.event("meeting-imported")
        } catch {
            Log.failure("meeting-import", error: error)
            importError = error.problem(or: Self.importFailed).message
            return
        }
        await refresh()
        selection = .meeting(meeting.id)
        let id = meeting.id
        Task { [processor] in await processor.process(id) }
    }

    public func dismissImportError() {
        importError = nil
    }

    private func change(_ id: UUID, _ edit: @Sendable (inout Meeting) -> Void) async {
        do {
            try await store.update(id, edit)
        } catch {
            Log.failure("meeting-change", error: error)
        }
        await refresh()
    }

    private func folderName(of id: UUID) -> String {
        entries.first { $0.id == .meeting(id) }?.folder ?? ""
    }

    // A closed folder keeps its selected meeting open; a search moves to its first hit.
    private func keepSelection() {
        let list = hits == nil ? entries : visible
        if selection == nil || !list.contains(where: { $0.id == selection }) {
            selection = visible.first?.id
        }
    }

    private func noteLanded(after old: [Entry]) {
        let wasBusy = Set(old.compactMap(busyID))
        landed += entries.compactMap { entry in
            guard case .meeting(let meeting, _) = entry, wasBusy.contains(meeting.id), state(of: meeting) == nil else { return nil }
            return meeting.id
        }
    }

    private func busyID(_ entry: Entry) -> UUID? {
        guard case .meeting(let meeting, _) = entry, case .work(let work)? = state(of: meeting), work.problem == nil else { return nil }
        return meeting.id
    }

    private static func newestFirst(_ first: Entry, _ second: Entry) -> Bool {
        first.date > second.date
    }

    public nonisolated static let readFailed = Problem("meetings.unreadable", "The meetings could not be read. Try again.", canRetry: true)
    static let importFailed = Problem("meeting.import-failed", "The recording could not be imported. Try again.", canRetry: true)
}
