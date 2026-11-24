import Foundation

public enum CallEvent: Sendable, Equatable {
    case started(app: String)
    case ended
}

// A call is another app holding a microphone for 3 seconds. It ends once that app has let go of the microphone
// and stopped playing, because some apps release the microphone on mute. One call at a time: a second app raises nothing.
public actor CallDetector {
    public nonisolated let events: AsyncStream<CallEvent>

    private static let hold: Duration = .seconds(3)

    private let continuation: AsyncStream<CallEvent>.Continuation
    private let processes: any AudioProcessSource
    private let settings: SettingsStore
    private let clock: any Clock<Duration>
    private let ownPID = getpid()
    private var call: String?
    private var holding: [String: Task<Void, Never>] = [:]
    private var isStarted = false

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
    }

    // For good: the events end with it.
    public func stop() {
        processes.unwatch()
        holding.values.forEach { $0.cancel() }
        holding = [:]
        continuation.finish()
    }

    // The call held is forgotten, so one still going is raised again after the same 3 seconds as a new one.
    public func lookAgain() {
        call = nil
        review()
    }

    private func review() {
        let ignored = Set(settings.value(MeetingsSettings.ignoredApps))
        let others = processes.processes()
            .map { AudioProcess(pid: $0.pid, bundleID: Self.owner(of: $0.bundleID), isRunningInput: $0.isRunningInput, isRunningOutput: $0.isRunningOutput) }
            .filter { $0.pid != ownPID && !$0.bundleID.isEmpty && !ignored.contains($0.bundleID) }
        if let call {
            guard !others.contains(where: { $0.bundleID == call && ($0.isRunningInput || $0.isRunningOutput) }) else { return }
            self.call = nil
            continuation.yield(.ended)
        }
        let apps = Set(others.filter(\.isRunningInput).map(\.bundleID))
        for (app, wait) in holding where !apps.contains(app) {
            wait.cancel()
            holding[app] = nil
        }
        for app in apps where holding[app] == nil {
            holding[app] = Task { [weak self, clock] in
                guard (try? await clock.sleep(for: Self.hold)) != nil else { return }
                await self?.confirm(app)
            }
        }
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
        continuation.yield(.started(app: app))
    }
}
