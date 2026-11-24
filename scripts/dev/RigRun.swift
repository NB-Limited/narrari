import CoreAudio
import Foundation
import NarrariKit
import Synchronization

private let speechText = """
    The quarterly planning meeting starts with a short review of the budget. Maria asks whether the new office opens in March \
    or in April. Peter answers that the builders need two more weeks, so the team will move after the holidays. Everyone agrees \
    to send the final list of tasks by Friday afternoon.
    """

@MainActor
func recordingRig(isQuick: Bool, only: String?) async throws -> Bool {
    guard let loopback = RigDevice(uid: RigDevice.loopbackUID) else { throw RigError.refused("BlackHole 16ch is not installed") }
    try RigAccess.check(loopback)
    let original = loopback.rate
    let restore = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    restore.setEventHandler {
        var address = RigDevice.address(kAudioDevicePropertyNominalSampleRate)
        var rate = original
        AudioObjectSetPropertyData(loopback.id, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate)
        exit(130)
    }
    restore.resume()
    let scratch = URL.temporaryDirectory.appending(path: "narrari-rig-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var rows: [(RigRow, [String])] = []
    var notRun: [String] = []
    do {
        let speech = try await RigSpeech(in: scratch)
        for scenario in RigScenario.all(isQuick: isQuick) where only.map({ scenario.name.contains($0) }) ?? true {
            let recording = RigRecording(scenario: scenario, loopback: loopback, scratch: scratch, speech: speech)
            do {
                rows += try await recording.run()
            } catch RigError.notRun(let reason) {
                notRun.append("\(scenario.name): \(reason)")
            }
            print("done: \(scenario.name)")
        }
    } catch {
        print("rig stopped: \(error)")
    }
    try? await loopback.set(rate: original)
    try? FileManager.default.removeItem(at: scratch)
    printTable(rows)
    notRun.forEach { print("not run: \($0)") }
    print("loopback device back at \(Int(loopback.rate)) Hz (was \(Int(original)) Hz)")
    return !rows.isEmpty && rows.allSatisfy(\.1.isEmpty) && loopback.rate == original
}

// The sentences spoken into the meeting, made by `say` into a file, never out loud.
struct RigSpeech {
    let file: URL
    let samples: [Float]
    let words: [String]

    init(in scratch: URL) async throws {
        file = scratch.appending(path: "speech.aiff")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", file.path, speechText]
        try say.run()
        say.waitUntilExit()
        samples = try await AudioFileDecoder.samples(from: file)
        words = normalizedWords(speechText)
    }
}

// The player as a process of its own, so the tap can take its sound alone, or leave it out.
func rigPlay(_ arguments: [String]) async throws {
    guard arguments.count == 5, let device = RigDevice(uid: arguments[0]), let start = Double(arguments[1]),
          let seconds = Double(arguments[2]), let channels = Int(arguments[3])
    else { throw RigError.player("usage") }
    let signal: @Sendable (Double) -> Float = arguments[4] == "tones"
        ? RigSignal.tone : RigSignal.speech(try await AudioFileDecoder.samples(from: URL(filePath: arguments[4])))
    let player = RigPlayer(device: device, channels: channels, start: start, signal: signal)
    try player.play()
    print("ready")
    fflush(stdout)
    while hostSeconds() < start + seconds + 1, getppid() != 1 { try await Task.sleep(for: .milliseconds(100)) }
    player.stop()
    print("stalled \(player.stalledSeconds)")
}

private func printTable(_ rows: [(RigRow, [String])]) {
    let heads = ["scenario", "track", "played s", "lost s", "right pitch s", "level dB", "device paused s", "offset ms", "drift ms", "apart ms", "corrected %",
                 "words", "result"]
    let lines = rows.map { row, faults -> [String] in
        let score = row.score
        let ms = { (value: Double?) in value.map { String(format: "%.1f", $0 * 1_000) } ?? "-" }
        return [
            row.scenario, row.track, String(format: "%.1f", score.played), row.isSpeech ? "-" : String(format: "%.2f", score.lost),
            row.isSpeech ? "-" : String(format: "%.1f", score.correct), String(format: "%.0f", score.levelDecibels),
            String(format: "%.2f", row.paused), ms(score.offset),
            ms(score.drift), ms(row.apart), row.corrected.map(String.init) ?? "-", row.words.map { "\($0.heard)/\($0.spoken)" } ?? "-",
            faults.isEmpty ? "pass" : "FAIL " + faults.joined(separator: ", ")
        ]
    }
    let widths = heads.indices.map { column in ([heads] + lines).map { $0[column].count }.max() ?? 0 }
    for line in [heads] + lines {
        print(zip(line, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  "))
    }
    let failed = rows.filter { !$0.1.isEmpty }.count
    print("\(rows.count - failed) of \(rows.count) rows pass")
}
