import AVFoundation
import Foundation
import NarrariKit

// Two audio files replayed as a meeting's microphone and system sound, into a meeting under `dataFolder`, never the real one.
// With live text on until `liveMinutes` (nil: off), the replay runs in real time, as the recognisers would hear it.
@MainActor
func meetingReplay(
    _ paths: (microphone: String, system: String), into dataFolder: String, minutes: Double?, fastPPM: Double, liveMinutes: Double?
) async throws {
    let microphone = try await AudioFileDecoder.samples(from: URL(filePath: paths.microphone))
    let system = try await AudioFileDecoder.samples(from: URL(filePath: paths.system))
    let seconds = minutes.map { $0 * 60 } ?? Double(max(microphone.count, system.count)) / SpeechAudio.sampleRate
    let data = URL(filePath: dataFolder)
    let store = MeetingStore(root: data.appending(path: "Meetings"), trash: MeetingStore.moveToTrash)
    let meeting = Meeting(title: "Replay", startedAt: .now, app: "", source: .manual, template: "general", state: .recording)
    let folder = try await store.create(meeting, appName: "")
    let replay = Replay(microphone: microphone, system: system, microphonePartsPerMillionFast: fastPPM)
    guard let defaults = UserDefaults(suiteName: data.appending(path: "settings").path) else { return }
    let settings = SettingsStore(defaults: defaults)
    let recorder = MeetingRecorder(
        settings: settings,
        permissions: Permissions(settings: settings, access: InputAccess(isAccessibilityGranted: { true }), microphoneStatus: { .authorized }),
        inputs: replay, system: replay, freeSpace: MeetingRecorder.volumeFreeSpace, hostNow: { replay.clock.hostTime },
        clock: ContinuousClock()
    )
    let live = try await liveTranscript(for: recorder, in: data, settings: settings, isOn: liveMinutes != nil)
    try recorder.start(in: folder)
    live.start()
    var reading = LiveReading()
    while liveMinutes != nil, !live.isListening, live.notice == nil { try await Task.sleep(for: .milliseconds(20)) }
    let began = ContinuousClock.now
    print(String(format: "memory at start: %.0f MB", memoryMegabytes().footprint))
    var played = 0.0
    while played < seconds {
        let step = min(liveMinutes == nil ? 60 : 0.1, seconds - played)
        replay.play(seconds: step)
        played += step
        // Paced at 120 times real time without live text, so the writer keeps up as it would live and memory shows what a
        // meeting holds.
        try await Task.sleep(until: began + .seconds(liveMinutes == nil ? played / 120 : played), clock: .continuous)
        reading.look(at: live, after: played)
        if let liveMinutes, played >= liveMinutes * 60, settings.value(MeetingsSettings.showsLiveText) {
            settings.set(false, for: MeetingsSettings.showsLiveText)
            print(String(format: "live text off at %.1f min", played / 60))
        }
        if played.truncatingRemainder(dividingBy: 600) < step / 2 {
            print(String(format: "memory after %.0f min: %.0f MB", played / 60, memoryMegabytes().footprint))
        }
    }
    guard let recording = recorder.stop() else { return }
    let lines = live.lines
    await live.stop()
    try await store.update(meeting.id) { meeting in
        meeting.durationMs = Int((recording.duration / .milliseconds(1)).rounded())
        meeting.state = .ready
    }
    print(String(format: "memory at stop: %.0f MB, peak while recording: %.0f MB", memoryMegabytes().footprint, reading.peakMegabytes))
    if liveMinutes != nil { reading.report(notice: live.notice, lines: lines) }
    print("meeting:  \(folder.path)")
    print(String(format: "duration: %.3f s, system sound heard: %@", recording.duration / .seconds(1), recording.heardSystemSound ? "yes" : "no"))
    try printTracks(in: folder, isOneSource: paths.microphone == paths.system)
}

func printTracks(in folder: URL, isOneSource: Bool) throws {
    let tracks = try ["mic.caf", "system.caf"].map { try AVAudioFile(forReading: folder.appending(path: $0)) }
    for (name, file) in zip(["mic.caf", "system.caf"], tracks) {
        let format = file.fileFormat.streamDescription.pointee
        print(String(
            format: "%@: %.3f s, %lld frames, %.0f Hz, %u channel, %u bit", name, Double(file.length) / format.mSampleRate, file.length,
            format.mSampleRate, format.mChannelsPerFrame, format.mBitsPerChannel
        ))
    }
    if isOneSource { print(String(format: "track offset over the last 10 s: %.1f ms", try offset(tracks) * 1000)) }
}

// Live text from the speech model in the scratch folder, downloaded there first if it is missing.
@MainActor
func liveTranscript(for recorder: MeetingRecorder, in data: URL, settings: SettingsStore, isOn: Bool) async throws -> LiveTranscript {
    settings.set(isOn, for: MeetingsSettings.showsLiveText)
    let models = ModelStore(root: data.appending(path: "Models"))
    if isOn, !models.isPresent(named: settings.value(SpeechSettings.localModel).folder) {
        print("downloading the speech model into the scratch folder")
        let download = ParakeetTranscriber(store: models, settings: settings)
        try await download.load()
        await download.unload()
    }
    return LiveTranscript(recorder: recorder, speech: ParakeetLiveSpeech(store: models, settings: settings), settings: settings)
}

// How long after it was said each final word showed, read from the lines between steps of the replay.
struct LiveReading {
    private var ends: [Int: Double] = [:]
    private var delays: [Double] = []
    private(set) var peakMegabytes = 0.0

    // A line that grew since the last look holds words said after its old end, so the time since that end bounds their delay.
    @MainActor
    mutating func look(at live: LiveTranscript, after played: Double) {
        peakMegabytes = max(peakMegabytes, memoryMegabytes().footprint)
        for line in live.lines where ends[line.id] != line.end {
            delays.append(played - (ends[line.id] ?? line.start))
            ends[line.id] = line.end
        }
    }

    func report(notice: LiveTextNotice?, lines: [LiveTranscript.Line]) {
        for line in lines.prefix(4) { print(String(format: "%6.1f s %@: %@", line.start, line.speaker, line.text)) }
        let sorted = delays.sorted()
        guard !sorted.isEmpty else { return print("live text: no final words; notice: \(notice?.message ?? "none")") }
        print(String(
            format: "live text: %d lines grew %d times; delay after speech median %.1f s, 90th percentile %.1f s, worst %.1f s",
            ends.count, sorted.count, sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted[sorted.count - 1]
        ))
    }
}

// The lag in seconds that best lines up the last 10 s of the two tracks, searched within 100 ms either way.
func offset(_ tracks: [AVAudioFile]) throws -> Double {
    let rate = SpeechAudio.sampleRate
    let window = Int(10 * rate)
    let reach = Int(0.1 * rate)
    let tails = try tracks.map { file -> [Float] in
        let count = window + 2 * reach
        file.framePosition = max(0, file.length - AVAudioFramePosition(count))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return [] }
        try file.read(into: buffer)
        return buffer.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength))) } ?? []
    }
    guard tails.count == 2, tails.allSatisfy({ $0.count == window + 2 * reach }) else { return .nan }
    var best = (lag: 0, score: -Float.infinity)
    for lag in -reach...reach {
        var score: Float = 0
        for index in 0..<window { score += tails[0][reach + index] * tails[1][reach + index + lag] }
        if score > best.score { best = (lag, score) }
    }
    return Double(best.lag) / rate
}
