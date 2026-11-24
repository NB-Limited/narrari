import Foundation

// One step of the work after a meeting. It reads and writes the meeting through the store.
public protocol MeetingStep: Sendable {
    // Throws WaitReason to leave the step waiting with its reason; any other error marks it failed.
    func run(_ id: UUID, in store: MeetingStore) async throws
}

// A model a step can wait for: one of the meeting's own, or the speech or clean-up model dictation shares.
public enum NeededModel: Hashable, Sendable {
    case meeting(AudioModel)
    case speech
    case cleanup

    static let all = AudioModel.allCases.map(Self.meeting) + [.speech, .cleanup]
}

public protocol MeetingModelSupply: Sendable {
    // Returns at once; the downloads go on.
    func begin(_ models: [NeededModel]) async
    // True once every one is on this Mac, false when a download failed.
    func download(_ models: [NeededModel]) async -> Bool
}

extension WaitReason {
    // The models to download for a step waiting for this.
    var models: [NeededModel] {
        switch self {
        case .speechModel: [.speech]
        case .echoModels: [.meeting(.speechDetection), .meeting(.echoRemoval)]
        case .speakerModel: [.meeting(.speakerSplit)]
        case .cleanupModel: [.cleanup]
        case .echoRemoval, .transcript, .dictation, .turn: []
        }
    }

    // Files written before the codes kept the sentence the page showed.
    init?(sentence: String) {
        let sentences: [String: Self] = [
            "Waiting for the speech model to be downloaded.": .speechModel,
            "Waiting for the echo removal models to be downloaded.": .echoModels,
            "Waiting for the speaker model to be downloaded.": .speakerModel,
            "Waiting for the clean-up model to be downloaded.": .cleanupModel,
            "Waiting for echo removal.": .echoRemoval,
            "Waiting for the transcript.": .transcript,
            "Waiting for dictation to finish.": .dictation
        ]
        guard let waiting = sentences[sentence] else { return nil }
        self = waiting
    }
}

// Runs the steps after a meeting in order and keeps each one's state in meeting.json. A step that is done or failed is
// not run again until it is retried; a step whose input is not done waits, and a later step that does not need it still runs.
public actor MeetingProcessing {
    public enum Step: CaseIterable, Sendable {
        case echo
        case transcript
        case speakers
        case summary

        var input: Step? {
            switch self {
            case .echo: nil
            case .transcript: .echo
            case .speakers, .summary: .transcript
            }
        }

        var waitingFor: WaitReason? {
            switch self {
            case .echo: .echoRemoval
            case .transcript: .transcript
            case .speakers, .summary: nil
            }
        }

        public var failure: Problem {
            switch self {
            case .echo: Problem("meeting.echo-failed", "Echo removal failed. Try again.", canRetry: true)
            case .transcript: Problem("meeting.transcript-failed", "The transcript could not be written. Try again.", canRetry: true)
            case .speakers: Problem("meeting.speakers-failed", "Speakers could not be told apart. Try again.", canRetry: true)
            case .summary: Problem("meeting.summary-failed", "The summary could not be written. Try again.", canRetry: true)
            }
        }

        // A code this version does not know, such as one from a later version, reads as the step's own failure.
        public func problem(_ code: String?) -> Problem {
            code.flatMap { Self.stored[$0] } ?? failure
        }

        private static let stored: [String: Problem] = {
            let problems = AudioFileError.allCases.map(\.problem) + TranscriberError.allCases.map(\.problem)
                + SummaryError.allCases.map(\.problem) + SummaryTemplateError.allCases.map(\.problem)
                + MeetingSpeakers.Failure.allCases.map(\.problem) + MeetingError.allCases.map(\.problem) + allCases.map(\.failure)
                + TrackWriterError.allCases.map(\.problem) + [TimeLimitExceeded().problem, AudioModelError.notDownloaded.problem]
            return Dictionary(problems.map { ($0.code, $0) }) { first, _ in first }
        }()
    }

    private let store: MeetingStore
    private let workers: [Step: any MeetingStep]
    private let models: (any MeetingModelSupply)?
    private var underWay: Set<UUID> = []
    private var again: Set<UUID> = []

    // Without speakers or summary those steps stay waiting; without models a step that needs one waits until retried.
    public init(
        store: MeetingStore, echo: any MeetingStep, transcript: any MeetingStep, speakers: (any MeetingStep)? = nil,
        summary: (any MeetingStep)? = nil, models: (any MeetingModelSupply)? = nil
    ) {
        self.store = store
        var workers: [Step: any MeetingStep] = [.echo: echo, .transcript: transcript]
        workers[.speakers] = speakers
        workers[.summary] = summary
        self.workers = workers
        self.models = models
    }

    // Every model a meeting may need starts downloading, so it is on this Mac by the time the meeting ends.
    public func prepare() async {
        await models?.begin(AudioModel.allCases.map(NeededModel.meeting))
    }

    // At launch; the meetings with work left are processed after this returns, so the launch waits on no step or model.
    public func resume() async {
        var unfinished: [UUID] = []
        do {
            try await store.recover()
            for meeting in try await store.meetings().meetings where meeting.state != .recording {
                let cutOff = Step.allCases.filter { meeting.steps[$0].status == .running }
                if !cutOff.isEmpty {
                    try await store.update(meeting.id) { meeting in cutOff.forEach { meeting.steps[$0] = Meeting.Step(.waiting) } }
                }
                if Step.allCases.contains(where: { [.waiting, .running].contains(meeting.steps[$0].status) }) { unfinished.append(meeting.id) }
            }
        } catch {
            Log.failure("meeting-resume-store", error: error)
        }
        Task { for id in unfinished { await process(id) } }
    }

    // A model landed, however it was downloaded: every meeting with a step waiting for one goes through again.
    public func carryOn() async {
        do {
            for meeting in try await store.meetings().meetings where meeting.state != .recording && Step.allCases.contains(where: {
                meeting.steps[$0].status == .waiting && !(meeting.steps[$0].waiting?.models ?? []).isEmpty
            }) {
                await process(meeting.id)
            }
        } catch {
            Log.failure("meeting-carry-on-store", error: error)
        }
    }

    // A meeting already being processed goes through once more when that run ends; one still recording or importing waits until it is done.
    public func process(_ id: UUID) async {
        guard underWay.insert(id).inserted else {
            again.insert(id)
            return
        }
        defer { underWay.remove(id) }
        repeat {
            again.remove(id)
            await runSteps(id)
        } while again.contains(id) && !Task.isCancelled
    }

    private func runSteps(_ id: UUID) async {
        do {
            guard try await !store.meeting(id).state.isTakingAudio else { return }
            for step in Step.allCases {
                let steps = try await store.meeting(id).steps
                guard steps[step].status != .done, steps[step].status != .failed else { continue }
                if let input = step.input, steps[input].status != .done {
                    try await mark(step, of: id, Meeting.Step(.waiting, for: input.waitingFor))
                    continue
                }
                guard let worker = workers[step] else {
                    try await mark(step, of: id, Meeting.Step(.waiting))
                    continue
                }
                try await mark(step, of: id, await run(worker, step, of: id))
                if Task.isCancelled { return }
            }
        } catch {
            Log.failure("meeting-processing-store", error: error)
        }
    }

    // Runs the step again with every step that takes its result; while the meeting is processed, after the steps under way.
    public func retry(_ step: Step, of id: UUID) async {
        let again = Step.allCases.filter { $0 == step || needs($0, step) }
        do {
            try await store.update(id) { meeting in again.forEach { meeting.steps[$0] = Meeting.Step(.waiting) } }
        } catch {
            Log.failure("meeting-retry-store", error: error)
            return
        }
        await process(id)
    }

    private func needs(_ step: Step, _ other: Step) -> Bool {
        guard let input = step.input else { return false }
        return input == other || needs(input, other)
    }

    // A step waiting for a model waits here while it downloads, then runs once more; a failed download leaves it waiting.
    private func run(_ worker: any MeetingStep, _ step: Step, of id: UUID) async throws -> Meeting.Step {
        try await mark(step, of: id, Meeting.Step(.running, since: .now))
        let outcome = await attempt(worker, step, of: id)
        let needed = outcome.waiting?.models ?? []
        guard outcome.status == .waiting, !needed.isEmpty, let models else { return outcome }
        await models.begin(needed)
        try await mark(step, of: id, outcome)
        guard await models.download(needed), !Task.isCancelled else { return outcome }
        try await mark(step, of: id, Meeting.Step(.running, since: .now))
        return await attempt(worker, step, of: id)
    }

    private func attempt(_ worker: any MeetingStep, _ step: Step, of id: UUID) async -> Meeting.Step {
        let start = ContinuousClock.now
        do {
            try await worker.run(id, in: store)
            Self.logTiming(step, (ContinuousClock.now - start) / .seconds(1))
            return Meeting.Step(.done)
        } catch let waiting as WaitReason {
            return Meeting.Step(.waiting, for: waiting)
        } catch is CancellationError {
            return Meeting.Step(.waiting)
        } catch {
            Log.failure("meeting-step", error: error)
            return Meeting.Step(.failed, problem: error.problem(or: step.failure).code)
        }
    }

    private func mark(_ step: Step, of id: UUID, _ state: Meeting.Step) async throws {
        try await store.update(id) { $0.steps[step] = state }
    }

    private static func logTiming(_ step: Step, _ seconds: Double) {
        switch step {
        case .echo: Log.timing("meeting-step-echo", seconds: seconds)
        case .transcript: Log.timing("meeting-step-transcript", seconds: seconds)
        case .speakers: Log.timing("meeting-step-speakers", seconds: seconds)
        case .summary: Log.timing("meeting-step-summary", seconds: seconds)
        }
    }
}

extension Meeting.Steps {
    public subscript(step: MeetingProcessing.Step) -> Meeting.Step {
        get {
            switch step {
            case .echo: echo
            case .transcript: transcript
            case .speakers: speakers
            case .summary: summary
            }
        }
        set {
            switch step {
            case .echo: echo = newValue
            case .transcript: transcript = newValue
            case .speakers: speakers = newValue
            case .summary: summary = newValue
            }
        }
    }
}
