import Foundation
import NarrariKit
import Synchronization
import Testing

struct MeetingProcessingTests {
    private let folder = TemporaryFolder()
    private let store: MeetingStore
    private let runs = Notes<String>()

    init() {
        store = MeetingStore(root: folder.url, trash: { _ in })
    }

    private final class FakeStep: MeetingStep {
        private let name: String
        private let runs: Notes<String>
        let outcome: Mutex<(any Error)?>

        init(_ name: String, runs: Notes<String>, failing error: (any Error)? = nil) {
            self.name = name
            self.runs = runs
            outcome = Mutex(error)
        }

        func run(_ id: UUID, in store: MeetingStore) async throws {
            let state = try await store.meeting(id).steps
            runs.add("\(name) \([state.echo, state.transcript, state.speakers, state.summary].map(\.status.rawValue))")
            if let error = outcome.withLock({ $0 }) { throw error }
        }
    }

    private struct Broken: Error {}

    private func newMeeting() async throws -> UUID {
        let meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .manual, template: "general", state: .ready)
        try await store.create(meeting, appName: "")
        return meeting.id
    }

    private func steps(_ id: UUID) async throws -> Meeting.Steps {
        try await store.meeting(id).steps
    }

    private var names: [String] { runs.all.map { String($0.prefix { $0 != " " }) } }

    @Test func steps_run_in_order_each_marked_running_then_done_and_missing_ones_wait() async throws {
        let id = try await newMeeting()
        let processing = MeetingProcessing(
            store: store, echo: FakeStep("echo", runs: runs), transcript: FakeStep("transcript", runs: runs)
        )

        await processing.process(id)

        #expect(runs.all == [
            #"echo ["running", "waiting", "waiting", "waiting"]"#,
            #"transcript ["done", "running", "waiting", "waiting"]"#
        ])
        let steps = try await steps(id)
        #expect(steps.echo == Meeting.Step(.done) && steps.transcript == Meeting.Step(.done))
        #expect(steps.speakers == Meeting.Step(.waiting) && steps.summary == Meeting.Step(.waiting))
    }

    @Test func a_failed_step_holds_back_only_the_steps_that_need_it_and_a_retry_runs_it_alone() async throws {
        let id = try await newMeeting()
        let speakers = FakeStep("speakers", runs: runs, failing: Broken())
        let processing = MeetingProcessing(
            store: store, echo: FakeStep("echo", runs: runs), transcript: FakeStep("transcript", runs: runs),
            speakers: speakers, summary: FakeStep("summary", runs: runs)
        )

        await processing.process(id)
        await processing.process(id)
        let afterFailure = try await steps(id)
        speakers.outcome.withLock { $0 = nil }
        await processing.retry(.speakers, of: id)

        #expect(afterFailure.speakers.status == .failed && afterFailure.speakers.reason != nil)
        #expect(afterFailure.summary == Meeting.Step(.done))
        #expect(names == ["echo", "transcript", "speakers", "summary", "speakers"])
        #expect(try await steps(id).speakers == Meeting.Step(.done))
    }

    @Test func try_again_while_the_meeting_is_processed_waits_at_once_and_runs_after_the_step_under_way() async throws {
        let id = try await newMeeting()
        let speakers = FakeStep("speakers", runs: runs, failing: Broken())
        let held = Gate()
        let processing = MeetingProcessing(
            store: store, echo: FakeStep("echo", runs: runs), transcript: FakeStep("transcript", runs: runs),
            speakers: speakers, summary: GatedStep(gate: held)
        )

        let run = Task { await processing.process(id) }
        await held.waitForArrivals(1)
        speakers.outcome.withLock { $0 = nil }
        await processing.retry(.speakers, of: id)
        let shown = try await steps(id).speakers
        held.open()
        await run.value

        #expect(shown == Meeting.Step(.waiting))
        #expect(names == ["echo", "transcript", "speakers", "speakers"])
        #expect(try await steps(id).speakers == Meeting.Step(.done))
    }

    // The held step proves the launch does not wait: resume returns while it is still under way.
    @Test(.timeLimit(.minutes(1)))
    func at_launch_a_step_cut_off_mid_run_and_a_cut_off_recording_carry_on_after_resume_returns() async throws {
        let cutOffStep = try await newMeeting()
        try await store.update(cutOffStep) { meeting in
            meeting.steps.echo = Meeting.Step(.done)
            meeting.steps.transcript = Meeting.Step(.running, since: .distantPast)
        }
        let cutOffRecording = Meeting(title: "Call", startedAt: .now, app: "", source: .manual, template: "general", state: .recording)
        try await store.create(cutOffRecording, appName: "")
        let held = Gate()
        let summaries = Gate.counter()
        let processing = MeetingProcessing(
            store: store, echo: FakeStep("echo", runs: runs), transcript: GatedStep(gate: held), summary: GatedStep(gate: summaries)
        )

        await processing.resume()
        await held.waitForArrivals(1)
        held.open()
        await summaries.waitForPasses(2)

        #expect(try await steps(cutOffStep).transcript == Meeting.Step(.done))
        #expect(try await store.meeting(cutOffRecording.id).state == .recovered)
        #expect(try await steps(cutOffRecording.id).transcript == Meeting.Step(.done))
    }

    @Test func a_step_waiting_for_a_model_keeps_its_reason_and_what_needs_it_waits_until_it_is_done() async throws {
        let id = try await newMeeting()
        let echo = FakeStep("echo", runs: runs, failing: MeetingStepWaiting("Waiting for the echo removal models to be downloaded."))
        let processing = MeetingProcessing(
            store: store, echo: echo, transcript: FakeStep("transcript", runs: runs), summary: FakeStep("summary", runs: runs)
        )

        await processing.process(id)
        let waiting = try await steps(id)
        echo.outcome.withLock { $0 = nil }
        await processing.process(id)

        #expect(waiting.echo == Meeting.Step(.waiting, reason: "Waiting for the echo removal models to be downloaded."))
        #expect(waiting.transcript == Meeting.Step(.waiting, reason: "Waiting for echo removal."))
        #expect(waiting.summary == Meeting.Step(.waiting, reason: "Waiting for the transcript."))
        #expect(names == ["echo", "echo", "transcript", "summary"])
        #expect(try await steps(id).summary == Meeting.Step(.done))
    }
}

// The summary step as far as the clean-up model goes, which dictation shares.
private final class NeedsCleanupModel: MeetingStep {
    let isOnThisMac = Mutex(false)
    let passes = Gate.counter()

    func run(_ id: UUID, in store: MeetingStore) async throws {
        guard isOnThisMac.withLock({ $0 }) else { throw MeetingStepWaiting("Waiting for the clean-up model to be downloaded.") }
        try await passes.pass()
    }
}

// The speaker step as far as its model goes: it waits until the model is on this Mac.
private struct NeedsSpeakerModel: MeetingStep {
    let models: ModelStore

    func run(_ id: UUID, in store: MeetingStore) async throws {
        guard models.isPresent(named: AudioModel.speakerSplit.folder) else {
            throw MeetingStepWaiting("Waiting for the speaker model to be downloaded.")
        }
    }
}

@MainActor
struct MeetingProcessingModelTests {
    private let folder = TemporaryFolder()
    private let summaries = Gate.counter()
    private let store: MeetingStore
    private let models: ModelStore

    init() {
        store = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in })
        models = ModelStore(root: folder.url.appending(path: "Models"))
    }

    private func processing(_ library: MeetingModels) -> MeetingProcessing {
        MeetingProcessing(
            store: store, echo: NoStep(), transcript: NoStep(), speakers: NeedsSpeakerModel(models: models),
            summary: GatedStep(gate: summaries), models: library
        )
    }

    private func newMeeting() async throws -> UUID {
        let meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .manual, template: "general", state: .ready)
        try await store.create(meeting, appName: "")
        return meeting.id
    }

    @Test func getting_ready_downloads_every_meeting_model_not_on_this_mac() async throws {
        let present = models.directory(named: AudioModel.speechDetection.folder)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: present.appending(path: "model.bin"))
        let fetch = FakeModelFetch(store: models)
        let library = MeetingModels(store: models, fetch: fetch.fetch)

        await processing(library).prepare()

        await until { [AudioModel.echoRemoval, .speakerSplit].allSatisfy { if case .onThisMac = library.status(of: $0) { true } else { false } } }
        #expect(Set(fetch.fetched.all) == [.echoRemoval, .speakerSplit])
    }

    @Test func a_step_missing_its_model_downloads_it_and_carries_on() async throws {
        let id = try await newMeeting()
        let fetch = FakeModelFetch(store: models)
        let library = MeetingModels(store: models, fetch: fetch.fetch)

        await processing(library).process(id)

        let steps = try await store.meeting(id).steps
        #expect(steps.speakers == Meeting.Step(.done) && steps.summary == Meeting.Step(.done))
        #expect(fetch.fetched.all == [.speakerSplit])
    }

    @Test func a_summary_waiting_for_the_clean_up_model_downloads_it_and_carries_on() async throws {
        let id = try await newMeeting()
        let summary = NeedsCleanupModel()
        let downloads = Notes<String>()
        let cleanup = SharedModel(size: { 1 }, state: { .missing }, isOnThisMac: { summary.isOnThisMac.withLock { $0 } }, download: {
            downloads.add("clean-up")
            summary.isOnThisMac.withLock { $0 = true }
            return true
        })
        let library = MeetingModels(store: models, fetch: FakeModelFetch(store: models).fetch, cleanup: cleanup)

        await MeetingProcessing(store: store, echo: NoStep(), transcript: NoStep(), summary: summary, models: library).process(id)

        #expect(downloads.all == ["clean-up"])
        #expect(try await store.meeting(id).steps.summary == Meeting.Step(.done))
    }

    @Test func a_model_downloaded_from_its_settings_page_carries_on_the_meeting_left_waiting_for_it() async throws {
        let id = try await newMeeting()
        let summary = NeedsCleanupModel()
        let status = ModelStatus()
        let cleanup = SharedModel(size: { 1 }, state: { status.state }, isOnThisMac: { summary.isOnThisMac.withLock { $0 } }, download: { false })
        let library = MeetingModels(store: models, fetch: FakeModelFetch(store: models).fetch, cleanup: cleanup)
        let processing = MeetingProcessing(store: store, echo: NoStep(), transcript: NoStep(), summary: summary, models: library)
        await processing.process(id)
        let waiting = try await store.meeting(id).steps.summary
        library.whenLanded { await processing.carryOn() }

        summary.isOnThisMac.withLock { $0 = true }
        status.report(.ready)

        await summary.passes.waitForPasses(1)

        #expect(waiting == Meeting.Step(.waiting, reason: "Waiting for the clean-up model to be downloaded."))
    }

    @Test func a_failed_download_holds_back_only_its_step_and_trying_again_finishes_it() async throws {
        let id = try await newMeeting()
        let fetch = FakeModelFetch(store: models)
        fetch.isFailing.withLock { $0 = true }
        let library = MeetingModels(store: models, fetch: fetch.fetch)
        let processing = processing(library)

        await processing.process(id)
        let afterFailure = try await store.meeting(id).steps
        fetch.isFailing.withLock { $0 = false }
        await processing.process(id)

        #expect(afterFailure.speakers == Meeting.Step(.waiting, reason: "Waiting for the speaker model to be downloaded."))
        #expect(afterFailure.summary == Meeting.Step(.done))
        #expect(try await store.meeting(id).steps.speakers == Meeting.Step(.done))
    }

    @Test func at_launch_a_meeting_left_waiting_for_a_model_carries_on() async throws {
        let id = try await newMeeting()
        var meeting = try await store.meeting(id)
        meeting.steps.echo = Meeting.Step(.done)
        meeting.steps.transcript = Meeting.Step(.done)
        meeting.steps.speakers = Meeting.Step(.waiting, reason: "Waiting for the speaker model to be downloaded.")
        try await store.save(meeting)
        let library = MeetingModels(store: models, fetch: FakeModelFetch(store: models).fetch)

        await processing(library).resume()

        await summaries.waitForPasses(1)
        #expect(try await store.meeting(id).steps.speakers == Meeting.Step(.done))
    }
}

private struct NoStep: MeetingStep {
    func run(_ id: UUID, in store: MeetingStore) async throws {}
}

private struct GatedStep: MeetingStep {
    let gate: Gate

    func run(_ id: UUID, in store: MeetingStore) async throws {
        try await gate.pass()
    }
}
