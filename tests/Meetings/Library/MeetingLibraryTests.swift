import Foundation
import NarrariKit
import Synchronization
import Testing

@MainActor
struct MeetingLibraryTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let processor = StartedProcessor()
    private let trashed = TrashBin()
    private let store: MeetingStore
    private let library: MeetingLibrary
    private let fetch: FakeModelFetch
    private let models: MeetingModels
    private let morning = try! Date("2026-11-20T09:00:00Z", strategy: .iso8601)

    init() {
        store = MeetingStore(root: folder.url, trash: { [trashed] in try trashed.add($0) })
        let modelStore = ModelStore(root: folder.url.appending(path: "Models"))
        fetch = FakeModelFetch(store: modelStore, isHeld: true)
        models = MeetingModels(store: modelStore, fetch: fetch.fetch)
        library = MeetingLibrary(store: store, processor: processor, models: models, settings: settings.store, recording: { nil })
    }

    @discardableResult
    private func saved(_ title: String, in app: String, hour: Double) async throws -> Meeting {
        let meeting = Meeting(
            title: title, startedAt: morning.addingTimeInterval(hour * 3_600), app: "", source: .call, template: "general", state: .ready
        )
        try await store.create(meeting, appName: app)
        return meeting
    }

    private var listed: [[String]] {
        library.groups.map { group in
            [group.name] + group.entries.map { entry in
                switch entry {
                case .meeting(let meeting, _): meeting.title
                case .unreadable(let url): "unreadable \(url.lastPathComponent)"
                }
            }
        }
    }

    @Test func folders_follow_their_newest_meeting_newest_first_inside_and_the_list_follows_new_meetings() async throws {
        try await saved("Contract review", in: "Zoom", hour: 0)
        try await saved("Weekly product sync", in: "Microsoft Teams", hour: 1)
        try await saved("Delivery plan", in: "Zoom", hour: 2)
        let broken = folder.url.appending(path: "Zoom/2026-11-20 1030")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appending(path: "meeting.json"))
        await library.refresh()

        #expect(listed == [
            ["Zoom", "Delivery plan", "unreadable 2026-11-20 1030", "Contract review"],
            ["Microsoft Teams", "Weekly product sync"]
        ])
        let following = Task { await library.follow() }
        defer { following.cancel() }
        try await saved("Hub walkthrough", in: "Microsoft Teams", hour: 3)
        await until { library.groups.first?.name == "Microsoft Teams" }
        #expect(listed.first == ["Microsoft Teams", "Hub walkthrough", "Weekly product sync"])
    }

    @Test func a_meeting_waiting_for_a_model_says_so_then_reads_downloading_while_it_downloads() async throws {
        var meeting = try await saved("Weekly", in: "Zoom", hour: 0)
        meeting.steps.speakers = Meeting.Step(.waiting, for: .speakerModel)
        let before = library.state(of: meeting)

        models.begin([AudioModel.speakerSplit])
        await until { library.state(of: meeting) == .work(.working(.downloading)) }
        fetch.gate.open()

        #expect(before == .work(.waiting(.speakerModel)) && WorkState.waiting(.speakerModel).label == "Waits for the speaker model")
    }

    @Test func a_pinned_meeting_leads_its_folder_and_a_meeting_is_renamed_to_untitled_moved_and_deleted() async throws {
        let meeting = try await saved("Delivery plan", in: "Zoom", hour: 0)
        try await saved("Contract review", in: "Zoom", hour: 1)
        await library.refresh()

        await library.togglePin(meeting.id)
        let pinnedFirst = listed
        await library.rename(meeting.id, to: "  ")
        await library.move(meeting.id, toFolder: "Velden Logistics")

        #expect(pinnedFirst == [["Zoom", "Delivery plan", "Contract review"]])
        #expect(listed == [["Zoom", "Contract review"], ["Velden Logistics", ""]])
        #expect(try await store.meeting(meeting.id).pinned)
        library.selection = .meeting(meeting.id)
        await library.delete(meeting.id)
        #expect(listed == [["Zoom", "Contract review"]])
        #expect(trashed.count == 1)
        #expect(library.selection != .meeting(meeting.id))
    }

    @Test func a_made_title_is_the_users_once_they_change_it() async throws {
        let meeting = try await saved("Budget review", in: "Zoom", hour: 0)
        try await store.update(meeting.id) { $0.titleIsMade = true }

        await library.rename(meeting.id, to: "Budget review ")
        let keptOnSameText = try await store.meeting(meeting.id).titleIsMade
        await library.rename(meeting.id, to: "Budget for 2027")

        #expect(keptOnSameText)
        #expect(try await store.meeting(meeting.id).titleIsMade == false)
    }

    @Test func search_lists_where_each_meeting_hit() async throws {
        let plan = try await saved("Delivery plan", in: "Zoom", hour: 1)
        try await store.write([
            TranscriptSegment(start: 0, end: 4, speaker: "owner", text: "Good morning.", track: .mic),
            TranscriptSegment(start: 5, end: 9, speaker: "owner", text: "The Rotterdam hub can take the first trucks.", track: .mic)
        ], of: plan.id)
        let review = try await saved("Contract review", in: "Zoom", hour: 0)
        try await store.write("Penalty clause for late arrivals in Rotterdam.", to: .notes, of: review.id)
        await library.refresh()

        library.searchText = "rotterdam"
        await library.search()

        #expect(library.visible.map(\.id) == [.meeting(plan.id), .meeting(review.id)])
        #expect(library.excerpt(of: plan.id) == "owner: The Rotterdam hub can take the first trucks.")
        #expect(library.excerpt(of: review.id) == "Notes: Penalty clause for late arrivals in Rotterdam.")
        #expect(library.selection == .meeting(plan.id))
    }

    @Test func recordings_dropped_together_each_become_a_meeting_in_imported_dated_by_their_file_and_their_steps_start() async throws {
        var files: [URL] = []
        for (name, day) in [("Hub walkthrough", morning), ("Kickoff", morning.addingTimeInterval(-86_400))] {
            let file = folder.url.appending(path: "\(name).wav")
            try WAVEncoder.encode(speech(seconds: 1), sampleRate: 16_000).write(to: file)
            try FileManager.default.setAttributes([.creationDate: day], ofItemAtPath: file.path)
            files.append(file)
        }
        var started = processor.started.makeAsyncIterator()

        await library.importRecordings(files)

        #expect(listed == [["Imported", "Hub walkthrough", "Kickoff"]])
        let meetings = try await store.meetings().meetings
        #expect(meetings.map(\.startedAt) == [morning, morning.addingTimeInterval(-86_400)])
        #expect(meetings.allSatisfy { $0.source == .import && $0.state == .ready && $0.durationMs == 1_000 })
        for meeting in meetings {
            #expect(FileManager.default.fileExists(atPath: try await store.audio(.microphone, of: meeting.id).path))
        }
        #expect(await Set([started.next(), started.next()]) == Set(meetings.map(\.id)))
    }

    @Test func a_recording_still_being_read_in_is_listed_as_importing_and_not_processed() async throws {
        let meeting = Meeting(title: "Kickoff", startedAt: morning, app: "", source: .import, template: "general", state: .importing)
        try await store.create(meeting, appName: "")

        #expect(library.state(of: meeting) == .work(.working(.importing)))
    }
}

// Tells which meetings were handed over for their steps.
final class StartedProcessor: MeetingProcessor {
    let started: AsyncStream<UUID>
    private let continuation: AsyncStream<UUID>.Continuation

    init() {
        (started, continuation) = AsyncStream.makeStream()
    }

    func prepare() async {}

    func process(_ meeting: UUID) async {
        continuation.yield(meeting)
    }
}

final class TrashBin: Sendable {
    private let items = Mutex<[URL]>([])

    var count: Int { items.withLock(\.count) }

    func add(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        items.withLock { $0.append(url) }
    }
}
