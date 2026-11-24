import AVFoundation
import Foundation
import NarrariKit
import Observation
import Synchronization

@MainActor
final class FakeHotkeys: HotkeySource {
    var onInput: ((HotkeyGesture.Input, TimeInterval) -> Void)?
    private(set) var recordingKeys: [RecordingKeys] = []

    func setRecordingKeys(_ keys: RecordingKeys) {
        recordingKeys.append(keys)
    }

    func send(_ input: HotkeyGesture.Input, at time: TimeInterval) {
        onInput?(input, time)
    }
}

@MainActor
final class FakeRecorder: AudioCapture {
    var onInterruption: (() -> Void)?
    var onSwitch: ((String?) -> Void)?
    var onFirstSound: (() -> Void)?
    var level: Float { 0 }
    private(set) var hasHeardSound = false
    private(set) var microphoneName: String? = "MacBook Pro Microphone"
    var startError: (any Error)?
    var samples: [Float]
    var problem: Problem?

    init(samples: [Float] = speech(seconds: 1)) {
        self.samples = samples
    }

    // The real recorder creates the audio file the moment it starts.
    func start(writingTo file: URL) throws {
        if let startError { throw startError }
        try Data("caff".utf8).write(to: file)
    }

    func stop() -> RecordedAudio { RecordedAudio(samples: samples, problem: problem) }

    func recentSamples(_ count: Int) -> [Float] { Array(samples.suffix(count)) }

    func unplug() { onInterruption?() }

    func hearSound() {
        hasHeardSound = true
        onFirstSound?()
    }

    func switchMicrophone(to name: String) {
        microphoneName = name
        onSwitch?(name)
    }
}

// Input devices in memory, so no test reads this Mac's microphones.
@MainActor
final class FakeMicrophones: MicrophoneSource {
    var devices: [Microphone]
    var automatic: String?
    private var onChange: (@MainActor () -> Void)?

    init(_ devices: [Microphone] = [], automatic: String? = nil) {
        self.devices = devices
        self.automatic = automatic ?? devices.first?.id
    }

    func read(prefersBuiltIn: Bool) -> (devices: [Microphone], automatic: String?) { (devices, automatic) }
    func watch(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func unwatch() { onChange = nil }

    func plug(_ microphone: Microphone) {
        devices.append(microphone)
        onChange?()
    }
}

final class FakeTranscriber: Transcriber {
    let name: String
    private let gate: Gate?
    private let reply: @Sendable ([Float]) throws -> Transcript
    private let calls = Mutex<[Int]>([])
    private let passes = Mutex((running: 0, unloadedDuringPass: false))
    let loads = Gate.counter()
    let unloads = Gate.counter()

    init(
        name: String = "Fake speech",
        gate: Gate? = nil,
        reply: @escaping @Sendable ([Float]) throws -> Transcript
    ) {
        self.name = name
        self.gate = gate
        self.reply = reply
    }

    convenience init(name: String = "Fake speech", text: String, gate: Gate? = nil) {
        self.init(name: name, gate: gate) { samples in
            Transcript(text: text, audioSeconds: Double(samples.count) / SpeechAudio.sampleRate)
        }
    }

    var sampleCounts: [Int] { calls.withLock { $0 } }
    var wasUnloadedDuringPass: Bool { passes.withLock { $0.unloadedDuringPass } }

    func load() async throws {
        try await loads.pass()
    }

    func unload() async {
        passes.withLock { if $0.running > 0 { $0.unloadedDuringPass = true } }
        try? await unloads.pass()
    }

    func transcribe(samples: [Float]) async throws -> Transcript {
        calls.withLock { $0.append(samples.count) }
        passes.withLock { $0.running += 1 }
        defer { passes.withLock { $0.running -= 1 } }
        try await gate?.pass()
        return try reply(samples)
    }
}

final class FakeCleanupEngine: CleanupEngine {
    struct Call: Sendable, Equatable {
        let transcript: String
        let instruction: String
        let growth: ReplyGrowth
    }

    let name: String
    let runsInApp: Bool
    let loads = Gate.counter()
    let unloads = Gate.counter()
    private let gate: Gate?
    private let reply: @Sendable (String) throws -> String
    private let recorded = Mutex<[Call]>([])
    private let current: Mutex<ModelState>

    init(
        name: String = "Fake clean-up",
        runsInApp: Bool = true,
        state: ModelState = .ready,
        gate: Gate? = nil,
        reply: @escaping @Sendable (String) throws -> String
    ) {
        self.name = name
        self.runsInApp = runsInApp
        current = Mutex(state)
        self.gate = gate
        self.reply = reply
    }

    var calls: [Call] { recorded.withLock { $0 } }
    var state: ModelState { current.withLock { $0 } }

    // Counted once the model is ready.
    func load() async throws {
        current.withLock { $0 = .ready }
        try await loads.pass()
    }

    func unload() async {
        current.withLock { $0 = .missing }
        try? await unloads.pass()
    }

    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String {
        recorded.withLock { $0.append(Call(transcript: transcript, instruction: instruction, growth: growth)) }
        try await gate?.pass()
        return try reply(transcript)
    }
}

// Decodes pieces together as the in-app model does; a piece cleaned alone goes to `alone`.
final class FakeBatchCleanupEngine: BatchCleanupEngine {
    let alone: FakeCleanupEngine
    private let gate: Gate?
    private let replies: @Sendable ([String]) throws -> [String?]
    private let recorded = Mutex<[[String]]>([])

    init(
        gate: Gate? = nil,
        alone: FakeCleanupEngine = FakeCleanupEngine { $0.uppercased() },
        replies: @escaping @Sendable ([String]) throws -> [String?]
    ) {
        self.gate = gate
        self.alone = alone
        self.replies = replies
    }

    var batches: [[String]] { recorded.withLock { $0 } }
    var name: String { alone.name }
    var runsInApp: Bool { alone.runsInApp }
    var state: ModelState { alone.state }

    func load() async throws { try await alone.load() }
    func unload() async { await alone.unload() }

    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String {
        try await alone.rewrite(transcript, instruction: instruction, growth: growth)
    }

    func rewrite(together transcripts: [String], instruction: String, growth: ReplyGrowth) async throws -> [String?] {
        recorded.withLock { $0.append(transcripts) }
        try await gate?.pass()
        return try replies(transcripts)
    }
}

@MainActor
@Observable
final class FakeMuting: OutputMuting {
    private(set) var mutes = 0
    private(set) var restores = 0

    func muteOutput() async {
        mutes += 1
    }

    func restoreOutput() async {
        restores += 1
    }
}

@MainActor
@Observable
final class FakeSounds: SoundPlaying {
    private(set) var played: [Sound] = []
    private(set) var previewed: [SoundSet] = []

    func play(_ sound: Sound) async {
        played.append(sound)
    }

    func preview(_ set: SoundSet) async {
        previewed.append(set)
    }
}

@MainActor
final class FakePasteboard: Pasteboard {
    private(set) var changeCount = 0
    private var contents: [[PasteboardEntry]]

    init(_ contents: [[PasteboardEntry]] = []) {
        self.contents = contents
    }

    func items() -> [[PasteboardEntry]] { contents }

    @discardableResult
    func replace(with items: [[PasteboardEntry]]) -> Int {
        contents = items
        changeCount += 1
        return changeCount
    }

    var text: String? {
        contents.first?.first { $0.type == .string }.map { String(decoding: $0.data, as: UTF8.self) }
    }
}

extension Permissions {
    // Every grant from the test; nothing is asked of this Mac.
    static func fixed(
        settings: SettingsStore, access: InputAccess = .fixed(), microphone: AVAuthorizationStatus = .authorized,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> Permissions {
        Permissions(
            settings: settings, access: access, microphoneStatus: { microphone }, calendarStatus: { .denied }, askForCalendar: {}, clock: clock
        )
    }
}

extension InputAccess {
    static func fixed(accessibility: Bool = true, modifiersHeld: @escaping @Sendable () -> Bool = { false }) -> InputAccess {
        InputAccess(isAccessibilityGranted: { accessibility }, modifiersHeld: modifiersHeld)
    }
}

// A quiet tone rather than silence, so it reads as audio wherever it goes.
func speech(seconds: Double) -> [Float] {
    (0..<Int(seconds * SpeechAudio.sampleRate)).map { Float(sin(Double($0) * 0.05) * 0.25) }
}

// Keys in memory, so no test reads or writes the login Keychain.
final class FakeKeychain: KeyStoring {
    private let keys = Mutex<[String: String]>([:])

    func read(_ account: String) -> String? { keys.withLock { $0[account] } }
    func contains(_ account: String) -> Bool { read(account) != nil }
    func write(_ value: String, for account: String) { keys.withLock { $0[account] = value } }
    func delete(_ account: String) { _ = keys.withLock { $0.removeValue(forKey: account) } }
}

// Stands in for the network: a model downloads by gaining a file in the store, halfway first, or fails while failing is on.
final class FakeModelFetch: Sendable {
    let fetched = Notes<AudioModel>()
    let gate: Gate
    let isFailing = Mutex(false)
    private let store: ModelStore

    init(store: ModelStore, isHeld: Bool = false) {
        self.store = store
        gate = isHeld ? Gate() : .counter()
    }

    var fetch: MeetingModels.Fetch {
        { [self] model, progress in
            fetched.add(model)
            progress(0.5)
            try await gate.pass()
            if isFailing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            let folder = store.directory(named: model.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: folder.appending(path: "model.bin"))
        }
    }
}
