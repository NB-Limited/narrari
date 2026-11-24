import Foundation
import Observation

public enum MenuPanelItem: Hashable, Sendable {
    case fix
    case note(MenuNote.Target)
    case lastDictation
    case mode
    case modeOption(String)
    case microphone
    case microphoneOption(String)
    case dictation
    case meeting
    case meetingPause
    case openMain
    case transcribeFile
    case importRecording
    case settings
    case permissions
    case about
    case quit
}

public enum MenuPanelAction: Equatable, Sendable {
    case toggleDictation
    case toggleMeeting
    case pauseOrResumeMeeting
    case openMain
    case transcribeFile
    case importRecording
    case openSettings
    case openPermissions
    case showAbout
    case quit
    case allowAccessibility
    case allowMicrophone
    case openSpeechSettings
    case open(MenuNote.Target)
}

public enum MenuPanelOutcome: Equatable, Sendable {
    case stayOpen
    case closeShowingCopied
    case close(then: MenuPanelAction)
}

public struct LastDictation: Equatable, Sendable {
    public let text: String
    public let meta: String
}

// The menu bar panel: what it shows, which row is highlighted, and what a row does.
// It reads the session, the library and the permissions as they are; it only ticks while open.
@MainActor
@Observable
public final class MenuPanel {
    public private(set) var isOpen = false
    public private(set) var highlighted: MenuPanelItem?
    public private(set) var isModeListOpen = false
    public private(set) var isMicrophoneListOpen = false
    public private(set) var isCopied = false
    private var now: Date
    private var elapsed: TimeInterval = 0
    private var meetingElapsed: TimeInterval = 0
    private var news: [MenuNote] = []

    @ObservationIgnored private let session: DictationSession
    @ObservationIgnored private let meetings: MeetingSession
    @ObservationIgnored private let meetingLibrary: MeetingLibrary
    @ObservationIgnored private let workNews: WorkNews
    @ObservationIgnored let microphones: Microphones
    @ObservationIgnored private let library: HistoryLibrary
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored let settings: SettingsMirror
    @ObservationIgnored private let pasteboard: any Pasteboard
    @ObservationIgnored private let appName: @MainActor (String) -> String
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let currentDate: () -> Date
    @ObservationIgnored private var ticking: Task<Void, Never>?

    private static let tick: Duration = .seconds(1)

    public init(
        session: DictationSession,
        meetings: MeetingSession,
        meetingLibrary: MeetingLibrary,
        workNews: WorkNews,
        microphones: Microphones,
        library: HistoryLibrary,
        permissions: Permissions,
        settings: SettingsMirror,
        pasteboard: any Pasteboard = SystemPasteboard(),
        appName: @escaping @MainActor (String) -> String,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.meetings = meetings
        self.meetingLibrary = meetingLibrary
        self.workNews = workNews
        self.microphones = microphones
        self.library = library
        self.permissions = permissions
        self.settings = settings
        self.pasteboard = pasteboard
        self.appName = appName
        self.clock = clock
        currentDate = now
        self.now = now()
    }

    public var status: MenuPanelStatus {
        MenuPanelStatus(
            AppStatus(session: session, permissions: permissions), meeting: meetings.state, meetingWork: meetingWork, hotkey: hotkey,
            elapsed: elapsed, meetingElapsed: meetingElapsed, now: now
        )
    }

    // A failed meeting first, while it stays failed; then work that ended since the panel was last opened.
    public var notes: [MenuNote] {
        let failed = failedMeetings
        return failed + news.filter { note in !failed.contains { $0.target == note.target } }
    }

    // What the mark on the menu bar icon is for: missing access, a speech model that could not load, or a failed meeting.
    public var attention: String? {
        if !permissions.isAccessibilityAllowed { return AppStatus.accessibilityMissing.title }
        if permissions.microphone == .denied { return AppStatus.microphoneMissing.title }
        if case .failed = session.modelState { return AppStatus.modelFailed.title }
        return failedMeetings.first?.state.label
    }

    private var failedMeetings: [MenuNote] {
        meetingLibrary.entries.compactMap { entry in
            guard case .meeting(let meeting, _) = entry, case .work(let work)? = meetingLibrary.state(of: meeting), work.problem != nil else { return nil }
            return MenuNote(target: .meeting(meeting.id), title: MeetingFormat.title(meeting), state: work)
        }
    }

    // The step under way in the meeting being processed: running before waiting, the newest meeting first.
    private var meetingWork: WorkState {
        let work = meetingLibrary.entries.compactMap { entry -> WorkState? in
            guard case .meeting(let meeting, _) = entry, case .work(let work)? = meetingLibrary.state(of: meeting), work.problem == nil else { return nil }
            return work
        }
        return work.first { $0.activity != nil } ?? work.first ?? .waiting(.turn)
    }

    public var dictation: DictationRow {
        DictationRow(session: session, status: AppStatus(session: session, permissions: permissions))
    }

    public var lastDictation: LastDictation? {
        guard let entry = library.lastDictation else { return nil }
        let source = entry.file.map { "from \($0)" } ?? "in \(appName(entry.app))"
        let age = EntryFormat.age(entry, now: now)
        let meta = age.map { "\(EntryFormat.time(entry)) \(source), \($0)" } ?? "\(EntryFormat.when(entry, now: now)) \(source)"
        return LastDictation(text: entry.finalText, meta: meta)
    }

    public var meetingTitle: String { meetings.isMeetingUnderWay ? "Stop meeting" : "Start meeting" }

    // Nil while no meeting records.
    public var meetingPauseTitle: String? {
        switch meetings.state {
        case .recording: "Pause meeting"
        case .paused: "Resume meeting"
        case .idle, .offered, .processing: nil
        }
    }

    public var modeChoice: ModeChoice { session.modeChoice }

    public var modeTitle: String {
        session.modeChoice.app.isEmpty ? "Mode" : "Mode for \(appName(session.modeChoice.app))"
    }

    public var hasModeChoice: Bool { session.modeChoice.modes.count > 1 }

    // Every row the keyboard can reach, top to bottom; disabled rows are left out.
    public var items: [MenuPanelItem] {
        var items: [MenuPanelItem] = []
        if status.fixTitle != nil { items.append(.fix) }
        items += notes.map { .note($0.target) }
        if lastDictation != nil { items.append(.lastDictation) }
        if hasModeChoice {
            items.append(.mode)
            if isModeListOpen { items += session.modeChoice.modes.map { .modeOption($0.id) } }
        }
        if hasMicrophoneChoice {
            items.append(.microphone)
            if isMicrophoneListOpen { items += microphoneOptions.map { .microphoneOption($0.id) } }
        }
        if dictation.isEnabled { items.append(.dictation) }
        items += meetingPauseTitle == nil ? [.meeting] : [.meetingPause, .meeting]
        return items + [.openMain, .transcribeFile, .importRecording, .settings, .permissions, .about, .quit]
    }

    public func open() {
        guard !isOpen else { return }
        isOpen = true
        permissions.refresh()
        session.refreshModeChoice()
        microphones.start()
        news = workNews.take()
        tick()
        highlighted = initialHighlight
        ticking = Task { [weak self, clock] in
            while (try? await clock.sleep(for: Self.tick)) != nil {
                self?.tick()
            }
        }
    }

    public func close() {
        isOpen = false
        ticking?.cancel()
        ticking = nil
        highlighted = nil
        isModeListOpen = false
        isMicrophoneListOpen = false
        isCopied = false
        news = []
        microphones.stop()
    }

    public func highlight(_ item: MenuPanelItem?) {
        guard item.map(items.contains) ?? true else { return }
        highlighted = item
    }

    public func moveHighlight(by offset: Int) {
        let list = items
        guard !list.isEmpty else { return }
        guard let current = highlighted, let index = list.firstIndex(of: current) else {
            highlighted = offset > 0 ? list.first : list.last
            return
        }
        highlighted = list[(index + offset % list.count + list.count) % list.count]
    }

    public func activate(_ item: MenuPanelItem) -> MenuPanelOutcome {
        guard items.contains(item) else { return .stayOpen }
        switch item {
        case .fix:
            guard case .problem(_, let fix) = status else { return .stayOpen }
            return .close(then: fix)
        case .note(let target): return .close(then: .open(target))
        case .lastDictation: return copyLastDictation()
        case .mode:
            isModeListOpen.toggle()
            return .stayOpen
        case .modeOption(let id):
            session.selectMode(id)
            isModeListOpen = false
            highlighted = .mode
            return .stayOpen
        case .microphone:
            isMicrophoneListOpen.toggle()
            return .stayOpen
        case .microphoneOption(let id):
            microphones.choose(id)
            isMicrophoneListOpen = false
            highlighted = .microphone
            return .stayOpen
        case .dictation: return .close(then: .toggleDictation)
        case .meeting: return .close(then: .toggleMeeting)
        case .meetingPause: return .close(then: .pauseOrResumeMeeting)
        case .openMain: return .close(then: .openMain)
        case .transcribeFile: return .close(then: .transcribeFile)
        case .importRecording: return .close(then: .importRecording)
        case .settings: return .close(then: .openSettings)
        case .permissions: return .close(then: .openPermissions)
        case .about: return .close(then: .showAbout)
        case .quit: return .close(then: .quit)
        }
    }

    public func copyLastDictation() -> MenuPanelOutcome {
        guard let text = lastDictation?.text else { return .stayOpen }
        Clipboard.copy(text, to: pasteboard)
        isCopied = true
        return .closeShowingCopied
    }

    // A recording or a problem is what the panel is opened for; otherwise the last dictation, to copy it.
    private var initialHighlight: MenuPanelItem? {
        let list = items
        if list.contains(.fix) { return .fix }
        if let failed = failedMeetings.first { return .note(failed.target) }
        if session.phase == .recording || session.work == .waiting(.speechModel) { return .dictation }
        return list.contains(.lastDictation) ? .lastDictation : list.first
    }

    private func tick() {
        now = currentDate()
        elapsed = session.recordingSeconds
        meetingElapsed = meetings.recordedSeconds
    }
}
