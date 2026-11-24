import AVFoundation
import CoreAudio
import Foundation
import NarrariKit
import Synchronization

@MainActor
struct RigRecording {
    let scenario: RigScenario
    let loopback: RigDevice
    let scratch: URL
    let speech: RigSpeech

    private var isSpeech: Bool {
        if case .speech = scenario.sound { true } else { false }
    }

    private var seconds: Double {
        switch scenario.sound {
        case .tones(let seconds): seconds
        case .speech: Double(speech.samples.count) / SpeechAudio.sampleRate
        }
    }

    func run() async throws -> [(RigRow, [String])] {
        guard !loopback.isRunningSomewhere else { throw RigError.refused("another app is using the loopback device") }
        try await loopback.set(rate: scenario.rate)
        let microphoneUID = try microphone()
        let tapUID = try tapOutput()
        let folder = scratch.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = hostSeconds() + 1.5
        let (player, output) = try await spawnPlayer(start: start)
        defer { if player.isRunning { player.terminate() } }
        let began = Atomic<UInt64>(0)
        let tapped = scenario.tracks == .microphone ? getpid() : player.processIdentifier
        let watch = RigWatch(
            inputs: SystemAudioInputs(), system: SystemAudioCapture(outputUID: tapUID, onlyProcess: tapped), fault: scenario.fault, start: start
        )
        let recorder = try makeRecorder(microphoneUID: microphoneUID, watch: watch, in: folder) {
            let now = AudioGetCurrentHostTime()
            _ = began.compareExchange(expected: 0, desired: now, ordering: .relaxed)
            return now
        }
        let logged = Date.now
        try recorder.start(in: folder)
        for change in scenario.changes {
            try await sleep(until: start + change.at)
            try await loopback.set(rate: change.rate)
        }
        try await sleep(until: start + seconds + 0.5)
        recorder.stop()
        player.waitUntilExit()
        let said = String(bytes: try output.readToEnd() ?? Data(), encoding: .utf8) ?? ""
        let line = said.split(separator: "\n").first { $0.hasPrefix("stalled ") }
        guard let paused = line.flatMap({ Double($0.dropFirst(8)) }) else { throw RigError.player("it did not say how long it stalled") }
        let lead = start - Double(AudioConvertHostTimeToNanos(began.load(ordering: .relaxed))) / 1e9
        var rows = try await score(folder, lead: lead, paused: paused, report: RecorderReport.read(since: logged))
        // Up to about 2 s before and after the sound is silent by design; more on a played track is the loopback device's doing.
        for index in rows.indices where !rows[index].1.isEmpty {
            guard let side = RigWatch.Side(rawValue: rows[index].0.track) else { continue }
            let silent = watch.silentSeconds(of: side)
            if silent > 3 { rows[index].1.append(String(format: "loopback gave %.0f s of silence", silent)) }
        }
        if rows.contains(where: { !$0.1.isEmpty }) {
            print("watch: \(scenario.name), the player stalled \(paused) s; seconds from the sound's start:")
            watch.lines(since: start).forEach { print("watch:   " + $0) }
        }
        return rows
    }

    private func microphone() throws -> String {
        scenario.tracks == .system ? try idleSilentDevice().uid : loopback.uid
    }

    private func tapOutput() throws -> String {
        switch scenario.tap {
        case .loopback: return loopback.uid
        case .otherDevice: return try idleSilentDevice().uid
        case .multiOutput:
            guard let multi = loopback.aggregatesOfItselfAlone().first(where: { !$0.isRunningSomewhere && !$0.isDefault }) else {
                throw RigError.notRun("no idle multi-output device holding only the loopback device")
            }
            return multi.uid
        }
    }

    private func idleSilentDevice() throws -> RigDevice {
        guard let silent = RigDevice(uid: RigDevice.silentUID), !silent.isRunningSomewhere, !silent.isDefault else {
            throw RigError.notRun("no idle second silent device")
        }
        return silent
    }

    private func makeRecorder(
        microphoneUID: String, watch: RigWatch, in folder: URL, hostNow: @escaping @Sendable () -> UInt64
    ) throws -> MeetingRecorder {
        let settings = try scratchSettings(folder.appending(path: "settings"))
        settings.set(microphoneUID, for: DictationSettings.microphoneUID)
        settings.set(false, for: DictationSettings.prefersBuiltInOverBluetooth)
        // Access was read above without asking, so the recorder is told it is given and never asks itself.
        let permissions = Permissions(settings: settings, access: InputAccess(isAccessibilityGranted: { true }), microphoneStatus: { .authorized })
        return MeetingRecorder(
            settings: settings, permissions: permissions, inputs: watch, system: watch, freeSpace: MeetingRecorder.volumeFreeSpace,
            hostNow: hostNow, clock: ContinuousClock()
        )
    }

    private func spawnPlayer(start: Double) async throws -> (Process, FileHandle) {
        let player = Process()
        player.executableURL = Bundle.main.executableURL
        let sound = isSpeech ? speech.file.path : "tones"
        player.arguments = ["meeting", "rig-play", loopback.uid, String(start), String(seconds), String(scenario.channels), sound]
        let output = Pipe()
        player.standardOutput = output
        try player.run()
        for try await line in output.fileHandleForReading.bytes.lines where line == "ready" { return (player, output.fileHandleForReading) }
        throw RigError.player("it stopped before playing")
    }

    private func score(_ folder: URL, lead: Double, paused: Double, report: RecorderReport) async throws -> [(RigRow, [String])] {
        let sides: [(name: String, file: String, isPlayed: Bool)] = [
            ("mic", MeetingStore.Audio.microphone.rawValue, scenario.tracks != .system),
            ("system", MeetingStore.Audio.system.rawValue, scenario.tracks != .microphone)
        ]
        var rows: [RigRow] = []
        var silent: [[String]?] = []
        for side in sides {
            let url = folder.appending(path: side.file)
            let track = try await AudioFileDecoder.samples(from: url)
            guard side.isPlayed else {
                let level = 20 * log10(Double(max(RigScore.rms(track), 1e-9)))
                rows.append(RigRow(
                    scenario: scenario.name, track: side.name + " (silent)", score: TrackScore(levelDecibels: level),
                    corrected: report.corrected[side.name], words: nil, isSpeech: true, paused: paused
                ))
                silent.append(level > -60 ? ["heard sound"] : [])
                continue
            }
            let score = isSpeech
                ? RigScore.speech(track, lead: lead, reference: speech.samples) : RigScore.tones(track, lead: lead, seconds: seconds)
            let words = isSpeech ? try await heardWords(in: url) : nil
            rows.append(RigRow(
                scenario: scenario.name, track: side.name, score: score, corrected: report.corrected[side.name], words: words, isSpeech: isSpeech,
                paused: paused
            ))
            silent.append(nil)
        }
        if scenario.tracks == .both, scenario.fault == nil, let mic = rows.first?.score.offset, let system = rows.last?.score.offset {
            rows[0].apart = mic - system
        }
        let changes = scenario.changes.count
        let checks = checkFaults(report)
        return zip(rows, silent).map { row, silent in
            let allowed = scenario.fault.map { $0.sides.map(\.rawValue).contains(row.track) ? $0.allowedLoss : 0 } ?? 0
            return (row, (silent ?? row.faults(changes: changes, allowed: allowed)) + report.failures + checks)
        }
    }

    // The recorder's own checks: a fault the rig made is built again and never told; a scenario without one is neither.
    private func checkFaults(_ report: RecorderReport) -> [String] {
        var faults = report.told.map { "told \($0)" }
        let expected = Set(scenario.fault?.sides.map(\.rawValue) ?? [])
        if report.rebuilt != expected {
            faults.append(report.rebuilt.isEmpty ? "not rebuilt" : "rebuilt " + report.rebuilt.sorted().joined(separator: " and "))
        }
        return faults
    }

    private func heardWords(in track: URL) async throws -> (heard: Int, spoken: Int) {
        let settings = try scratchSettings(scratch.appending(path: "speech-settings"))
        let transcription = FileTranscription(store: .shared, settings: settings, dictionary: DictionaryStore(root: scratch))
        let heard = normalizedWords(try await transcription.run(track, upTo: nil) { _ in }.text)
        return (max(0, speech.words.count - wordErrors(reference: speech.words, hypothesis: heard)), speech.words.count)
    }

    private func scratchSettings(_ path: URL) throws -> SettingsStore {
        guard let defaults = UserDefaults(suiteName: path.path) else { throw CocoaError(.fileNoSuchFile) }
        return SettingsStore(defaults: defaults)
    }

    private func sleep(until host: Double) async throws {
        let wait = host - hostSeconds()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
    }
}
