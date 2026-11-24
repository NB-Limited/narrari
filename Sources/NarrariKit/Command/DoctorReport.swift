import Foundation

// What narrari doctor found. Counts, sizes, names of devices and models, hosts: never a key, dictated text or anything of a meeting.
public struct DoctorFacts: Sendable {
    public struct Reported<Value: Sendable>: Sendable {
        public let value: Value
        public let at: String

        public init(_ value: Value, at: String) {
            self.value = value
            self.at = at
        }
    }

    public struct Input: Sendable {
        public let name: String
        public let transport: MicrophoneTransport
        public let isDefault: Bool
        public let isUsed: Bool

        public init(name: String, transport: MicrophoneTransport, isDefault: Bool, isUsed: Bool) {
            self.name = name
            self.transport = transport
            self.isDefault = isDefault
            self.isUsed = isUsed
        }
    }

    public struct Output: Sendable {
        public let name: String
        public let canMute: Bool

        public init(name: String, canMute: Bool) {
            self.name = name
            self.canMute = canMute
        }
    }

    public struct LocalModel: Sendable {
        public let name: String
        public let bytesOnDisk: Int64

        public init(name: String, bytesOnDisk: Int64) {
            self.name = name
            self.bytesOnDisk = bytesOnDisk
        }
    }

    // A nil host is an address Narrari refuses to use.
    public enum Service: Sendable {
        case off
        case on(host: String?)
    }

    public enum Cleanup: Sendable {
        case off
        case onThisMac(LocalModel)
        case outside(host: String?)
    }

    // Where an unfinished meeting stands: still taking its audio, or the first of its steps not done.
    public enum Unfinished: Hashable, Sendable {
        case recording
        case importing
        case at(MeetingProcessing.Step)
        case failed(MeetingProcessing.Step)
    }

    public struct Meetings: Sendable {
        public let count: Int
        public let unfinished: [Unfinished: Int]
        // Percent of each track the last recorded meeting lost; 100 for a system track no tap delivered.
        public let lastLost: (microphone: Int, system: Int)

        public init(_ meetings: [Meeting]) {
            var unfinished: [Unfinished: Int] = [:]
            for meeting in meetings {
                let place: Unfinished? = switch meeting.state {
                case .recording: .recording
                case .importing: .importing
                case .recovered, .ready:
                    MeetingProcessing.Step.allCases.first { meeting.steps[$0].status != .done }.map { step in
                        meeting.steps[step].status == .failed ? .failed(step) : .at(step)
                    }
                }
                if let place { unfinished[place, default: 0] += 1 }
            }
            count = meetings.count
            self.unfinished = unfinished
            let last = meetings.filter { !$0.state.isTakingAudio && $0.source != .import }.max { $0.startedAt < $1.startedAt }
            lastLost = (last?.microphoneLostPercent ?? 0, last?.systemSound == .notCaptured ? 100 : last?.systemLostPercent ?? 0)
        }
    }

    public var app: String
    public var system: String
    public var mac: String
    public var runningSince: String?
    public var microphone: Reported<Permissions.Microphone>?
    public var accessibility: Reported<Bool>?
    public var shortcutTap: Reported<SidedShortcutState>?
    public var inputs: [Input]
    public var isChosenMicrophoneMissing: Bool
    public var output: Output?
    public var speech: LocalModel
    public var speechService: Service
    public var cleanup: Cleanup
    public var meetingModels: [LocalModel]
    public var dataBytes: Int64?
    public var history: HistoryStore.Usage?
    public var meetings: Meetings?
    public var canSeeScreenWatch: Bool

    public init(
        app: String, system: String, mac: String, runningSince: String?,
        microphone: Reported<Permissions.Microphone>?, accessibility: Reported<Bool>?,
        shortcutTap: Reported<SidedShortcutState>?, inputs: [Input], isChosenMicrophoneMissing: Bool, output: Output?,
        speech: LocalModel, speechService: Service, cleanup: Cleanup, meetingModels: [LocalModel], dataBytes: Int64?,
        history: HistoryStore.Usage?, meetings: Meetings?, canSeeScreenWatch: Bool
    ) {
        self.app = app
        self.system = system
        self.mac = mac
        self.runningSince = runningSince
        self.microphone = microphone
        self.accessibility = accessibility
        self.shortcutTap = shortcutTap
        self.inputs = inputs
        self.isChosenMicrophoneMissing = isChosenMicrophoneMissing
        self.output = output
        self.speech = speech
        self.speechService = speechService
        self.cleanup = cleanup
        self.meetingModels = meetingModels
        self.dataBytes = dataBytes
        self.history = history
        self.meetings = meetings
        self.canSeeScreenWatch = canSeeScreenWatch
    }
}

// One line per fact; a line that keeps dictation from working as set up starts with "!", and makes the command exit 1.
public struct DoctorReport: Sendable {
    public let lines: [String]

    public init(facts: DoctorFacts) {
        var report = Lines()
        report.about(facts)
        report.permissions(facts)
        report.devices(facts)
        report.models(facts)
        report.data(facts)
        lines = report.lines
    }

    public var problems: Int { lines.filter { $0.hasPrefix("!") }.count }

    public var reply: Command.Reply {
        let summary = switch problems {
        case 0: "No problems found."
        case 1: "1 problem, marked with !."
        default: "\(problems) problems, marked with !."
        }
        return Command.Reply(output: (lines + ["", summary]).joined(separator: "\n") + "\n", errors: "", status: problems == 0 ? 0 : 1)
    }
}

private struct Lines {
    var lines: [String] = []

    mutating func fact(_ text: String) { lines.append(text) }
    mutating func problem(_ text: String) { lines.append("! " + text) }
    mutating func gap() { lines.append("") }

    mutating func about(_ facts: DoctorFacts) {
        fact("Narrari \(facts.app)")
        fact(facts.system)
        fact(facts.mac)
        if let since = facts.runningSince { fact("Narrari is running, since \(since)") } else { problem("Narrari is not running") }
        gap()
    }

    mutating func permissions(_ facts: DoctorFacts) {
        let unknown = facts.runningSince == nil
            ? "not known while Narrari is not running"
            : "not known: the log no longer holds Narrari's report from its start; quit and reopen Narrari to report it again"
        if let microphone = facts.microphone {
            let said = "reported by Narrari at \(microphone.at)"
            switch microphone.value {
            case .allowed: fact("Microphone access: allowed, \(said)")
            case .denied: problem("Microphone access: turned off in System Settings, \(said)")
            case .notAsked: problem("Microphone access: not allowed yet, \(said)")
            }
        } else {
            fact("Microphone access: \(unknown)")
        }
        if let accessibility = facts.accessibility {
            let said = "reported by Narrari at \(accessibility.at)"
            if accessibility.value { fact("Accessibility: allowed, \(said)") } else { problem("Accessibility: not allowed, \(said)") }
        } else {
            fact("Accessibility: \(unknown)")
        }
        if let tap = facts.shortcutTap {
            let said = "reported by Narrari at \(tap.at)"
            switch tap.value {
            case .none: fact("Right-hand shortcuts: none set")
            case .working: fact("Right-hand shortcuts: working, \(said)")
            case .notWorking: problem("Right-hand shortcuts: not working, macOS refused Narrari's key listener, \(said)")
            }
        } else {
            fact("Right-hand shortcuts: \(unknown)")
        }
        fact("System audio recording: macOS gives apps no way to check it")
        if facts.canSeeScreenWatch {
            fact("Screen sharing: Narrari can tell when the screen is shared, and hides meeting controls then")
        } else {
            fact("Screen sharing: this macOS does not say when the screen is shared, so only the window setting hides meeting controls")
        }
        gap()
    }

    mutating func devices(_ facts: DoctorFacts) {
        if facts.inputs.isEmpty { problem("Microphones: none connected") } else { fact("Microphones:") }
        for input in facts.inputs {
            var parts = [input.name, input.transport.name]
            if input.isDefault { parts.append("system default") }
            if input.isUsed { parts.append("Narrari records from this one") }
            fact("  " + parts.joined(separator: ", "))
        }
        if !facts.inputs.isEmpty, !facts.inputs.contains(where: \.isUsed) { problem("Narrari has no microphone to record from") }
        if facts.isChosenMicrophoneMissing { fact("Chosen microphone: not connected, so Narrari uses the system default") }
        if let output = facts.output {
            let mute = output.canMute ? "can be muted" : "has no mute switch, so Narrari silences other apps instead"
            fact("Output: \(output.name), \(mute)")
        } else {
            fact("Output: none")
        }
        gap()
    }

    mutating func models(_ facts: DoctorFacts) {
        if facts.speech.bytesOnDisk > 0 {
            fact("Speech: \(facts.speech.name), on this Mac, \(size(facts.speech.bytesOnDisk))")
        } else {
            problem("Speech: \(facts.speech.name), not downloaded yet")
        }
        switch facts.speechService {
        case .off: fact("Speech service: off")
        case .on(let host?): fact("Speech service: on, \(host)")
        case .on(nil): problem("Speech service: on, but Narrari can't use its address")
        }
        switch facts.cleanup {
        case .off:
            fact("Clean-up: off")
        case .onThisMac(let model) where model.bytesOnDisk > 0:
            fact("Clean-up: \(model.name), on this Mac, \(size(model.bytesOnDisk))")
        case .onThisMac(let model):
            problem("Clean-up: \(model.name), not downloaded yet")
        case .outside(let host?):
            fact("Clean-up: chat service, \(host)")
        case .outside(nil):
            problem("Clean-up: chat service, but Narrari can't use its address")
        }
        fact("Meeting models:")
        for model in facts.meetingModels {
            fact("  \(model.name), " + (model.bytesOnDisk > 0 ? "on this Mac, \(size(model.bytesOnDisk))" : "not downloaded"))
        }
        gap()
    }

    mutating func data(_ facts: DoctorFacts) {
        if let bytes = facts.dataBytes { fact("Data folder: \(size(bytes))") } else { problem("Data folder: could not be read") }
        if let history = facts.history {
            let count = history.dictations == 1 ? "1 dictation" : "\(history.dictations) dictations"
            fact("History: \(count), \(size(history.bytes)) with their audio")
        } else {
            problem("History: could not be read")
        }
        guard let meetings = facts.meetings else { return problem("Meetings: could not be read") }
        let count = meetings.count == 1 ? "1 meeting" : "\(meetings.count) meetings"
        let unfinished = meetings.unfinished.values.reduce(0, +)
        fact("Meetings: \(count)" + (unfinished > 0 ? ", \(unfinished) unfinished:" : ""))
        let order = [DoctorFacts.Unfinished.recording, .importing] + MeetingProcessing.Step.allCases.flatMap { [.at($0), .failed($0)] }
        for place in order {
            if let count = meetings.unfinished[place] { fact("  \(count) \(Self.words(for: place))") }
        }
        for (track, lost) in [("microphone", meetings.lastLost.microphone), ("system sound", meetings.lastLost.system)] where lost >= 10 {
            problem("Last meeting: \(lost)% of its \(track) track was not recorded")
        }
    }

    private static func words(for place: DoctorFacts.Unfinished) -> String {
        switch place {
        case .recording: "still recording, or stopped by a quit or crash before it was saved"
        case .importing: "being imported"
        case .at(let step): "at the \(words(for: step))"
        case .failed(let step): "failed at the \(words(for: step))"
        }
    }

    private static func words(for step: MeetingProcessing.Step) -> String {
        switch step {
        case .echo: "echo removal"
        case .transcript: "transcript"
        case .speakers: "speakers"
        case .summary: "summary"
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
