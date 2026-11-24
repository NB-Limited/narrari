import Foundation

// What a piece of work is doing now, and the one line a person reads about it.
public enum WorkState: Sendable, Equatable {
    public enum Activity: Sendable, Equatable {
        case transcribing
        case cleaningUp
        case writingSummary
        case findingSpeakers
        case checkingForEcho
        case importing
        case downloading
        // Opening a model already on this Mac.
        case gettingReady
        // Reading a list from this Mac for the first time.
        case loading

        public var label: String {
            switch self {
            case .transcribing: "Transcribing"
            case .cleaningUp: "Cleaning up"
            case .writingSummary: "Writing the summary"
            case .findingSpeakers: "Finding speakers"
            case .checkingForEcho: "Checking for echo"
            case .importing: "Importing"
            case .downloading: "Downloading"
            case .gettingReady: "Getting ready"
            case .loading: "Loading"
            }
        }
    }

    case idle
    case waiting(WaitReason)
    case working(Activity, progress: Double? = nil, since: Date? = nil)
    case failed(Problem)
    case done

    // "Downloading, 46%"; empty while idle, so nothing shows.
    public var label: String {
        switch self {
        case .idle: ""
        case .waiting(let reason): reason.label
        case .working(let activity, let progress?, _): "\(activity.label), \(MetricText.percent(min(max(progress, 0), 1)))"
        case .working(let activity, nil, _): activity.label
        case .failed(let problem): problem.message
        case .done: "Done"
        }
    }

    // For a line too narrow for a problem's message, such as a list row; the message stays where the work is opened.
    public var brief: String {
        if case .failed = self { return "Failed" }
        return label
    }

    // "Finding speakers, 0:40" while it runs; a share of the work, once known, reads in place of the time.
    public func label(at now: Date) -> String {
        guard case .working(_, nil, let since?) = self else { return label }
        return "\(label), \(MeetingSurfaces.elapsedText(seconds: max(now.timeIntervalSince(since), 0)))"
    }

    public var activity: Activity? {
        if case .working(let activity, _, _) = self { return activity }
        return nil
    }

    public var progress: Double? {
        if case .working(_, let progress, _) = self { return progress }
        return nil
    }

    public var problem: Problem? {
        if case .failed(let problem) = self { return problem }
        return nil
    }
}

// What waiting work waits for. Meeting files store it by its raw value, so a raw value never changes once shipped.
public enum WaitReason: String, Error, Codable, Sendable {
    case speechModel = "speech-model"
    case echoModels = "echo-models"
    case speakerModel = "speaker-model"
    case cleanupModel = "cleanup-model"
    case echoRemoval = "echo-removal"
    case transcript
    case dictation
    // Queued behind other work; never stored.
    case turn

    public var label: String {
        switch self {
        case .speechModel: "Waits for the speech model"
        case .echoModels: "Waits for the echo removal models"
        case .speakerModel: "Waits for the speaker model"
        case .cleanupModel: "Waits for the clean-up model"
        case .echoRemoval: "Waits for echo removal"
        case .transcript: "Waits for the transcript"
        case .dictation: "Waits for dictation to finish"
        case .turn: "Waits for its turn"
        }
    }
}

extension ModelState {
    // A model on its way: "Downloading, 46%" while its bytes arrive, "Getting ready" while it opens; idle otherwise.
    public var work: WorkState {
        switch self {
        case .preparing(let fraction, isDownloading: true): .working(.downloading, progress: fraction)
        case .preparing: .working(.gettingReady)
        case .missing, .ready: .idle
        case .failed(let problem): .failed(problem)
        }
    }
}
