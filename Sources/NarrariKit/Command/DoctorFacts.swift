import AppKit
import CoreAudio

extension DoctorFacts {
    // Reads the Mac without changing it: nothing is requested, no microphone is opened, no history text is shown.
    @MainActor
    static func collect(in context: Command.Context) async -> DoctorFacts {
        let settings = context.settings
        let running = runningApp()
        let reports = running.map(appReports(of:)) ?? AppReports()
        let devices = inputs(settings)
        return DoctorFacts(
            app: version(),
            system: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            mac: "\(hardwareModel()), \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)) memory",
            runningSince: running.map { $0.since.map(localTime) ?? "an unknown time" },
            microphone: reports.microphone,
            accessibility: reports.accessibility,
            shortcutTap: reports.shortcutTap,
            inputs: devices.inputs,
            isChosenMicrophoneMissing: devices.isChosenMissing,
            output: output(),
            speech: speech(settings, context.models),
            speechService: settings.value(SpeechSettings.usesRemote) ? .on(host: host(settings.value(SpeechSettings.remoteAddress))) : .off,
            cleanup: cleanup(settings, context.models),
            meetingModels: MeetingModels.all.map { LocalModel(name: $0.name, bytesOnDisk: bytes(of: $0.folder, in: context.models)) },
            dataBytes: try? ModelStore.bytes(in: context.dataFolder),
            history: try? await context.history.usage(),
            meetings: (try? await context.meetings.meetings().meetings).map(Meetings.init),
            canSeeScreenWatch: SkyLightScreenWatcher().isAvailable
        )
    }

    static func version() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var model = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return "Mac" }
        return String(bytes: model.prefix { $0 != 0 }, encoding: .utf8) ?? "Mac"
    }

    private static func runningApp() -> (pid: pid_t, since: Date?)? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { $0.processIdentifier != getpid() })
        else { return nil }
        return (app.processIdentifier, ProcessClock.startDate(of: app.processIdentifier))
    }

    public struct AppReports: Sendable {
        public var microphone: Reported<Permissions.Microphone>?
        public var accessibility: Reported<Bool>?
        public var shortcutTap: Reported<SidedShortcutState>?
    }

    // A command started in a terminal is given the terminal's permissions, so the app's own report in the log is read instead.
    private static func appReports(of app: (pid: pid_t, since: Date?)) -> AppReports {
        let window = app.since.map { ["--start", localTime($0)] } ?? ["--last", "1d"]
        let kinds = #"(eventMessage BEGINSWITH "event permission-" OR eventMessage BEGINSWITH "event shortcut-tap-")"#
        guard case .success(let lines) = AppLog.read(window, matching: "processID == \(app.pid) AND \(kinds)") else { return AppReports() }
        return appReports(in: lines)
    }

    // The newest report of each wins; `log` is the output of log show --style ndjson.
    public static func appReports(inLog log: Data) -> AppReports {
        appReports(in: AppLog.lines(in: log))
    }

    private static func appReports(in lines: [AppLog.Line]) -> AppReports {
        var reports = AppReports()
        let at = { (line: AppLog.Line) in String(line.timestamp.prefix(19)) }
        for line in lines {
            if let value = Permissions.Microphone.allCases.first(where: { line.eventMessage == "event \($0.logName)" }) {
                reports.microphone = Reported(value, at: at(line))
            }
            if let value = [true, false].first(where: { line.eventMessage == "event \(Permissions.accessibilityLogName(isAllowed: $0))" }) {
                reports.accessibility = Reported(value, at: at(line))
            }
            if let value = SidedShortcutState.allCases.first(where: { line.eventMessage == "event \($0.logName)" }) {
                reports.shortcutTap = Reported(value, at: at(line))
            }
        }
        return reports
    }

    private static func inputs(_ settings: SettingsStore) -> (inputs: [Input], isChosenMissing: Bool) {
        let devices = AudioDevices.inputDevices()
        let systemDefault = AudioDevices.defaultInput()
        let uid = settings.value(DictationSettings.microphoneUID)
        let chosen = uid.isEmpty ? nil : AudioDevices.device(uid: uid)
        let transports = devices.map { (device: $0, transport: AudioDevices.transport(of: $0)) }
        let pick = MicrophonePick.resolve(
            chosen: chosen, systemDefault: systemDefault, inputs: transports,
            prefersBuiltIn: settings.value(DictationSettings.prefersBuiltInOverBluetooth)
        )
        let inputs = transports.map { device, transport in
            Input(
                name: AudioDevices.name(of: device) ?? AudioDevices.uid(of: device) ?? "A microphone with no name",
                transport: MicrophoneTransport(transport), isDefault: device == systemDefault, isUsed: device == pick?.device
            )
        }
        return (inputs, !uid.isEmpty && chosen == nil)
    }

    @MainActor
    private static func output() -> Output? {
        let mute = OutputDeviceMute()
        guard let uid = mute.defaultOutputUID() else { return nil }
        let name = AudioDevices.device(uid: uid).flatMap(AudioDevices.name(of:)) ?? uid
        return Output(name: name, canMute: mute.hasMute(uid))
    }

    private static func speech(_ settings: SettingsStore, _ models: ModelStore) -> LocalModel {
        let model = settings.value(SpeechSettings.localModel)
        return LocalModel(name: model.name, bytesOnDisk: models.isPresent(model) ? (try? models.bytesOnDisk(named: model.folder)) ?? 0 : 0)
    }

    // A model a download left half written reads as not downloaded.
    private static func bytes(of folder: String, in models: ModelStore) -> Int64 {
        models.isPresent(named: folder) ? (try? models.bytesOnDisk(named: folder)) ?? 0 : 0
    }

    private static func cleanup(_ settings: SettingsStore, _ models: ModelStore) -> Cleanup {
        guard settings.value(CleanupSettings.isEnabled) else { return .off }
        switch settings.value(CleanupSettings.engine) {
        case .chat:
            return .outside(host: host(settings.value(CleanupSettings.chatAddress)))
        case .local:
            let model = ModelReference(settings.value(CleanupSettings.localModel))
            let bytes = (try? LocalModelEngine(model: model, store: models).bytesOnDisk()) ?? 0
            return .onThisMac(LocalModel(name: model.displayName, bytesOnDisk: bytes))
        }
    }

    private static func host(_ address: String) -> String? {
        (try? ServiceAddress(address))?.url.host()
    }

    // The form log show reads as a start time, so the one function serves the report and the query.
    private static func localTime(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: .current)
                .year().month().day().time(includingFractionalSeconds: false)
        )
    }
}
