import Foundation
import NarrariKit
import Testing

@MainActor
final class SessionRig {
    let folder = TemporaryFolder()
    let settings = ThrowawaySettings()
    let clock = TestClock()
    let hotkeys = FakeHotkeys()
    let recorder = FakeRecorder()
    let media = FakeMuting()
    let sounds = FakeSounds()
    let modelStatus = ModelStatus()
    let pasteboard = FakePasteboard([[PasteboardEntry(type: .string, data: Data("copied by the user".utf8))]])
    let history: HistoryStore
    let modes: ModeStore
    var frontmost = "com.apple.TextEdit"
    var makesKeystroke = true
    var timing = HotkeyGesture.Timing(holdThreshold: 0.5, shortcutWindow: 0.2, minimumRecording: 0.3)
    static let ownApp = "com.nb-limited.narrari"
    private(set) var pastes: [(phase: DictationSession.Phase, text: String?)] = []
    private(set) var session: DictationSession!

    init(
        transcriber: any Transcriber = FakeTranscriber(text: "hello from the test"),
        outside: FakeTranscriber? = nil,
        engine: (any CleanupEngine)? = FakeCleanupEngine { _ in "Hello from the test." },
        access: InputAccess = .fixed()
    ) {
        let historyFolder = folder.url.appending(path: "History", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true)
        history = HistoryStore(root: historyFolder)
        modes = ModeStore(root: folder.url)
        settings.store.set(0, for: DictationSettings.clipboardRestoreDelay)

        let cleanup = CleanupService(engine: engine, settings: settings.store, clock: clock)
        let pipeline = TextPipeline(
            cleanup: cleanup,
            prompts: PromptStore(root: folder.url),
            dictionary: DictionaryStore(root: folder.url),
            settings: settings.store
        )
        let paster = Paster(
            pasteboard: pasteboard, access: access, settings: settings.store,
            postPaste: { [weak self] in
                guard let self, makesKeystroke else { return false }
                pastes.append((session.phase, pasteboard.text))
                return true
            },
            clock: clock
        )
        session = DictationSession(
            hotkeys: hotkeys, recorder: recorder, transcriber: transcriber, outsideTranscriber: { outside },
            modelStatus: modelStatus, livePreview: LivePreview(transcriber: transcriber, clock: clock),
            pipeline: pipeline, paster: paster, media: media, sounds: sounds, history: history, modes: modes,
            settings: settings.store, timing: { [weak self, timing] in self?.timing ?? timing },
            now: { [clock] in clock.seconds }, clock: clock, frontmostApp: { [weak self] in self?.frontmost }, ownApp: Self.ownApp
        )
    }

    // Presses the key and lets the shortcut window pass on the clock, so the dictation counts.
    func pressAndConfirm() async {
        let window = Duration.seconds(timing.shortcutWindow)
        let windowEnd = clock.now.advanced(by: window)
        hotkeys.send(.hotkeyDown, at: clock.seconds)
        await clock.waitForSleeper(until: windowEnd)
        clock.advance(by: window)
        await until { self.session.isListening }
    }

    func release() {
        clock.advance(by: .milliseconds(400))
        hotkeys.send(.hotkeyUp, at: clock.seconds)
    }

    func dictate() async {
        await pressAndConfirm()
        release()
        await session.shutdown()
    }

    func entries() async throws -> [HistoryEntry] {
        try await history.entries().entries
    }

    func onlyEntry() async throws -> HistoryEntry {
        let entries = try await entries()
        try #require(entries.count == 1)
        return entries[0]
    }

    func hasAudio(_ entry: HistoryEntry) -> Bool {
        FileManager.default.fileExists(atPath: history.audioURL(for: entry.id).path)
    }

    var audioFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: history.root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "caf" } ?? []
    }
}
