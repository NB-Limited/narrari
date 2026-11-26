import Foundation

public enum CallEvent: Sendable, Equatable {
    case started(app: String)
    case ended
}

// A call is another app holding a microphone for 3 seconds. It ends once that app has let go of the microphone
// and stopped playing, because some apps release the microphone on mute. One call at a time: a second app raises nothing.
// Core Audio does not tell of every change, so the apps are read again every 2 seconds whatever it tells.
public actor CallDetector {
    public nonisolated let events: AsyncStream<CallEvent>

    private static let hold: Duration = .seconds(3)
    private static let recheck: Duration = .seconds(2)
    // macOS's own listeners for Siri, dictation and sound recognition take a microphone for seconds with no call behind it.
    private static let systemListeners: Set = [
        "com.apple.CoreSpeech", "com.apple.Siri", "com.apple.assistantd", "com.apple.accessibility.heard",
        "com.apple.SpeechRecognitionCore.speechrecognitiond"
    ]

    private let continuation: AsyncStream<CallEvent>.Continuation
    private let processes: any AudioProcessSource
    private let settings: SettingsStore
    private let clock: any Clock<Duration>
    private let ownPID = getpid()
    private var call: String?
    private var holding: [String: Task<Void, Never>] = [:]
    private var isStarted = false
    private var rechecking: Task<Void, Never>?

    public init(processes: any AudioProcessSource, settings: SettingsStore, clock: any Clock<Duration>) {
        self.processes = processes
        self.settings = settings
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: CallEvent.self)
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        processes.watch { [weak self] in await self?.review() }
        review()
        rechecking = Task { [weak self, clock] in
            while (try? await clock.sleep(for: Self.recheck)) != nil, let self { await self.review(isRecheck: true) }
        }
    }

    // For good: the events end with it.
    public func stop() {
        processes.unwatch()
        rechecking?.cancel()
        holding.values.forEach { $0.cancel() }
        holding = [:]
        continuation.finish()
    }

    // The call held is forgotten, so one still going is raised again after the same 3 seconds as a new one.
    public func lookAgain() {
        call = nil
        review()
    }

    // A change a recheck finds is one Core Audio did not tell of, or one whose notice has not arrived yet.
    private func review(isRecheck: Bool = false) {
        if let call {
            guard !others(reading: [.input, .output], of: call).contains(where: { $0.bundleID == call && ($0.isRunningInput || $0.isRunningOutput) })
            else { return }
            self.call = nil
            Log.event("call-ended")
            if isRecheck { Log.event("call-end-missed-by-notification") }
            continuation.yield(.ended)
        }
        let apps = Set(others(reading: .input).filter(\.isRunningInput).map(\.bundleID))
        for (app, wait) in holding where !apps.contains(app) {
            wait.cancel()
            holding[app] = nil
        }
        for app in apps where holding[app] == nil {
            Log.event("call-microphone-taken")
            if isRecheck { Log.event("call-microphone-missed-by-notification") }
            holding[app] = Task { [weak self, clock] in
                guard (try? await clock.sleep(for: Self.hold)) != nil else { return }
                await self?.confirm(app)
            }
        }
    }

    private func others(reading reads: AudioProcessReads, of app: String? = nil) -> [AudioProcess] {
        let ignored = Self.systemListeners.union(settings.value(MeetingsSettings.ignoredApps))
        let isOther = { [ownPID] (pid: pid_t, owner: String) in pid != ownPID && !owner.isEmpty && !ignored.contains(owner) && (app == nil || owner == app) }
        return processes.processes { isOther($0, Self.owner(of: $1)) ? reads : [] }
            .map { AudioProcess(pid: $0.pid, bundleID: Self.owner(of: $0.bundleID), isRunningInput: $0.isRunningInput, isRunningOutput: $0.isRunningOutput) }
            .filter { isOther($0.pid, $0.bundleID) }
    }

    // A browser or an Electron app holds the microphone in a helper process; the call belongs to the app that owns it.
    // WebKit's helpers serve every WebKit app, and Safari is the one that takes calls.
    static func owner(of bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        if let helper = parts.firstIndex(where: { $0.lowercased() == "helper" }), helper > 0 {
            return parts[..<helper].joined(separator: ".")
        }
        return bundleID.hasPrefix("com.apple.WebKit.") ? "com.apple.Safari" : bundleID
    }

    private func confirm(_ app: String) {
        guard !Task.isCancelled, call == nil else { return }
        call = app
        holding.values.forEach { $0.cancel() }
        holding = [:]
        Log.event("call-confirmed")
        continuation.yield(.started(app: app))
    }
}
