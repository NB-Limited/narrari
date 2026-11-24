@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Synchronization

// Live text's recognisers: a sliding-window job per track, both on one loaded copy of the files dictation's model
// uses. It never downloads; a model not on disk fails the load.
public actor ParakeetLiveSpeech: LiveSpeech {
    // 8 s before and 2 s after each 5 s step fill the model's 15 s input. A turn's last word is final once the step after
    // its own has run, so at most two steps and the 2 s after, 12 s, from when it is said.
    static let window = SlidingWindowAsrConfig(chunkSeconds: 5, leftContextSeconds: 8, rightContextSeconds: 2)

    private let store: ModelStore
    private let settings: SettingsStore
    private var models: AsrModels?
    private var runs: [Task<Void, Never>] = []
    private let inputs = Mutex<[TranscriptSegment.Track: AsyncStream<Heard>.Continuation]>([:])

    public init(store: ModelStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    public func load() async throws {
        guard models == nil else { return }
        let model = settings.value(SpeechSettings.localModel)
        guard store.isPresent(named: model.folder) else { throw TranscriberError.notDownloaded }
        models = try await AsrModels.downloadAndLoad(to: store.directory(named: model.folder), version: model.version)
    }

    public func edits(for track: TranscriptSegment.Track) throws -> AsyncThrowingStream<LiveEdit, any Error> {
        guard let models else { throw TranscriberError.notDownloaded }
        let (audio, input) = AsyncStream<Heard>.makeStream()
        let (edits, output) = AsyncThrowingStream<LiveEdit, any Error>.makeStream()
        inputs.withLock { inputs in
            inputs[track]?.finish()
            inputs[track] = input
        }
        let run = Task { await Self.recognise(audio, on: track, with: models, into: output) }
        output.onTermination = { _ in run.cancel() }
        runs.append(run)
        return edits
    }

    public nonisolated func hear(_ samples: UnsafeBufferPointer<Float>, at position: Double, on track: TranscriptSegment.Track) {
        let heard = Heard(samples: Array(samples), position: position)
        inputs.withLock { _ = $0[track]?.yield(heard) }
    }

    public func unload() async {
        inputs.withLock { inputs in
            inputs.values.forEach { $0.finish() }
            inputs = [:]
        }
        let finishing = runs
        runs = []
        finishing.forEach { $0.cancel() }
        for run in finishing { await run.value }
        models = nil
    }

    // A job ends once a window hears nothing new while words still wait, so the end of a turn becomes final without
    // waiting for that side to speak again. The next audio starts a new job.
    private static func recognise(
        _ audio: AsyncStream<Heard>, on track: TranscriptSegment.Track, with models: AsrModels,
        into output: AsyncThrowingStream<LiveEdit, any Error>.Continuation
    ) async {
        var job: Job?
        var finalTokens = 0
        do {
            for await heard in audio {
                if let finished = job, await finished.isIdle {
                    finalTokens += try await finished.finish()
                    job = nil
                }
                if job == nil {
                    job = try await Job(models: models, track: track, origin: heard.position, offset: finalTokens, output: output)
                }
                await job?.hear(heard.samples)
            }
        } catch {
            output.finish(throwing: error)
        }
        await job?.cancel()
        output.finish()
    }
}

private struct Heard: Sendable {
    let samples: [Float]
    let position: Double
}

// One sliding-window run. Its token positions are counted from `offset`, after the tokens of the jobs before it.
private actor Job {
    private let manager: SlidingWindowAsrManager
    private var reading: Task<Int, any Error>?
    private(set) var isIdle = false

    init(
        models: AsrModels, track: TranscriptSegment.Track, origin: Double, offset: Int,
        output: AsyncThrowingStream<LiveEdit, any Error>.Continuation
    ) async throws {
        manager = SlidingWindowAsrManager(config: ParakeetLiveSpeech.window)
        try await manager.loadModels(models)
        let updates = await manager.tokenUpdates
        try await manager.startStreaming(source: track == .mic ? .microphone : .system)
        reading = Task {
            do {
                return try await read(updates, origin: origin, offset: offset, into: output)
            } catch {
                output.finish(throwing: error)
                throw error
            }
        }
    }

    private func read(
        _ updates: AsyncThrowingStream<SlidingWindowTokenUpdate, any Error>, origin: Double, offset: Int,
        into output: AsyncThrowingStream<LiveEdit, any Error>.Continuation
    ) async throws -> Int {
        var count = 0
        for try await update in updates {
            let revision = update.revision
            count = revision.retainedTokenCount + update.tokens.count
            isIdle = update.tokens.isEmpty && revision.stableTokenCount < count
            output.yield(LiveEdit(
                retained: offset + revision.retainedTokenCount, stable: offset + revision.stableTokenCount,
                tokens: update.tokens.map { Self.token($0, from: origin) }
            ))
        }
        return count
    }

    func hear(_ samples: [Float]) async {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: SpeechAudio.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        await manager.streamAudio(buffer)
    }

    // Makes every token the job holds final, and returns how many it made in all.
    func finish() async throws -> Int {
        _ = try await manager.finish()
        return try await reading?.value ?? 0
    }

    func cancel() async {
        await manager.cancel()
        reading?.cancel()
    }

    private static func token(_ timing: TokenTiming, from origin: Double) -> LiveEdit.Token {
        let text = timing.token == ASRConstants.sentencePieceUnknownToken ? "" : timing.token
        return LiveEdit.Token(text: text, start: origin + timing.startTime, end: origin + timing.endTime)
    }
}
