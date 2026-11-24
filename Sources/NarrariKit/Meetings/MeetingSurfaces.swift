import Foundation
import Observation

public enum MeetingNotice: Sendable, Equatable {
    case refused(RecorderError)
    case failed(Problem)
    case stoppedForLowDisk
    case liveText(LiveTextNotice)

    static let couldNotStart = Problem("meeting.start-failed", "The meeting could not start. Try again.", canRetry: true)
    static let notSaved = Problem(
        "meeting.not-saved", "The meeting could not be saved. Its audio is kept; quit Narrari and open it again to recover it."
    )

    init(startError error: any Error) {
        self = if let refusal = error as? RecorderError { .refused(refusal) } else { .failed(error.problem(or: Self.couldNotStart)) }
    }

    public var message: String {
        switch self {
        case .refused(let error): error.problem.message
        case .failed(let problem): problem.message
        case .stoppedForLowDisk: "Recording stopped: the disk is nearly full. Free some space."
        case .liveText(let notice): notice.message
        }
    }
}

// What a meeting shows on screen: the call notice, and the meeting bar as the recorder pill or the corner chip. While the
// screen is shared or recorded none of it is drawn, a dictation's pill included.
@MainActor
@Observable
public final class MeetingSurfaces {
    public enum Bar: Sendable, Equatable {
        case recording
        case paused
        case callEnded(secondsLeft: Int)
        case notice(MeetingNotice)
        // Recording goes on with a track going wrong; it goes back to recording once the track is healthy.
        case trouble(RecordingTrouble)

        public var announcement: String {
            switch self {
            case .recording: "Recording meeting"
            case .paused: "Paused"
            case .callEnded(let left): "Call ended, stopping in \(left) seconds"
            case .notice(let notice): notice.message
            case .trouble(let trouble): trouble.message
            }
        }

        public var takesClicks: Bool {
            if case .notice = self { return false }
            return true
        }
    }

    public struct Offer: Sendable, Equatable {
        public let app: String
        public let title: String?
    }

    public private(set) var style: MeetingBar
    @ObservationIgnored public var onOpenMeeting: ((UUID) -> Void)?
    private var notice: MeetingNotice?
    private var isPointerInside = false

    @ObservationIgnored private let session: MeetingSession
    @ObservationIgnored private let dictation: DictationSession
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let lingering: TimedFlag
    @ObservationIgnored private var noticeEnd: Task<Void, Never>?
    @ObservationIgnored private var seen: (refused: Bool, lowDisk: Bool, notSaved: UUID?, liveText: LiveTextNotice?) = (false, false, nil, nil)

    static let chipLinger: Duration = .seconds(1)

    public init(session: MeetingSession, dictation: DictationSession, settings: SettingsStore, clock: any Clock<Duration>) {
        self.session = session
        self.dictation = dictation
        self.clock = clock
        lingering = TimedFlag(clock: clock)
        style = settings.value(MeetingsSettings.bar)
        let changes = SettingsChanges.updates(of: [MeetingsSettings.bar.key])
        Task { [weak self] in
            for await _ in changes { self?.style = settings.value(MeetingsSettings.bar) }
        }
        followNotices()
    }

    public var isHidden: Bool { session.isScreenWatched }

    // Nil with automatic start, which records at once, and while the screen is watched, so the offer waits.
    public var offer: Offer? {
        session.shownOffer.map { Offer(app: $0, title: session.offeredTitle) }
    }

    public var bar: Bar? {
        guard !isHidden else { return nil }
        if let left = session.stopCountdown { return .callEnded(secondsLeft: left) }
        if let notice { return .notice(notice) }
        switch session.state {
        case .recording: return session.trouble.map(Bar.trouble) ?? .recording
        case .paused: return .paused
        case .idle, .offered, .processing: return nil
        }
    }

    public var pill: Bar? { style == .pill ? bar : nil }

    public var chip: Bar? { style == .chip ? bar : nil }

    public var showsDictation: Bool { dictation.showsPill && !isHidden }

    // A dictation takes the capsule; the meeting waits beside it as a circle with its mark and takes no clicks.
    public var isFolded: Bool { pill != nil && showsDictation }

    public var showsPill: Bool { showsDictation || pill != nil }

    public var pillTakesClicks: Bool { !showsDictation && pill?.takesClicks == true }

    // The countdown, a notice and trouble open the chip by themselves; otherwise it opens under the pointer and closes a second after it leaves.
    public var isChipOpen: Bool {
        switch chip {
        case nil: false
        case .callEnded, .notice, .trouble: true
        case .recording, .paused: isPointerInside || lingering.isOn
        }
    }

    public var marksRecording: Bool { session.isMeetingUnderWay && !isHidden }

    // A click on the bar outside its buttons opens the meeting it records; folded beside a dictation or showing a notice it does nothing.
    public func barClicked() {
        guard let bar, bar.takesClicks, !isFolded, let id = session.recordingID else { return }
        onOpenMeeting?(id)
    }

    public func pointer(isInside: Bool) {
        guard isInside != isPointerInside else { return }
        isPointerInside = isInside
        if isInside { lingering.turnOff() } else { lingering.turnOn(for: Self.chipLinger) }
    }

    // "12:04", and "1:02:04" past the hour. The margin keeps a whole second summed from host times from reading as the one before.
    public nonisolated static func elapsedText(seconds: Double) -> String {
        let total = max(0, Int(seconds + 0.001))
        let (hours, minutes, rest) = (total / 3_600, total / 60 % 60, total % 60)
        let tail = String(format: "%02d", rest)
        return hours > 0 ? "\(hours):" + String(format: "%02d", minutes) + ":\(tail)" : "\(minutes):\(tail)"
    }

    public nonisolated static func countdownText(secondsLeft: Int) -> String {
        "Call ended, stopping in \(secondsLeft) s"
    }

    // A refused start, a stop for a full disk or one not saved, and live text stopping each show once, for as long as a dictation's notice.
    private func followNotices() {
        let now = withObservationTracking {
            (
                refused: session.startError.map(MeetingNotice.init(startError:)), lowDisk: session.stoppedForLowDisk,
                notSaved: session.notSaved, liveText: session.liveText?.notice
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.followNotices() }
        }
        if let refused = now.refused, !seen.refused {
            show(refused)
        } else if now.lowDisk, !seen.lowDisk {
            show(.stoppedForLowDisk)
        } else if let id = now.notSaved, id != seen.notSaved {
            show(.failed(MeetingNotice.notSaved))
        } else if let live = now.liveText, live != seen.liveText {
            show(.liveText(live))
        }
        seen = (now.refused != nil, now.lowDisk, now.notSaved, now.liveText)
    }

    private func show(_ notice: MeetingNotice) {
        self.notice = notice
        noticeEnd?.cancel()
        noticeEnd = Task { [weak self, clock] in
            guard (try? await clock.sleep(for: DictationSession.noticeDuration)) != nil else { return }
            self?.notice = nil
        }
    }
}
