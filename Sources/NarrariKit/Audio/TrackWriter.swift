import AudioToolbox
import AVFoundation

public enum TrackWriterError: ProblemError, Equatable, CaseIterable {
    case writeFailed

    public var problem: Problem {
        Problem("track.write-failed", "The audio could not be written to disk. Free some space, then try again.", canRetry: true)
    }
}

// One meeting track on disk: 16 kHz mono 16-bit CAF. At most a second of audio waits in memory, so a crash loses at most that.
// Used from one thread at a time.
public final class TrackWriter {
    public typealias Write = (ExtAudioFileRef, UInt32, UnsafePointer<AudioBufferList>) -> OSStatus

    private static let rate = SpeechAudio.sampleRate
    private static let flushSamples = Int(rate)
    // How far the track may run ahead of or behind the meeting's clock before samples are added or dropped.
    private static let toleranceSamples = Int(0.01 * rate)

    private var file: ExtAudioFileRef?
    // Nil while the source is at the speech rate already.
    private var resampler: Resampler?
    private var sourceRate: Double
    // Frames given to the resampler and frames it gave back: it holds some back, so its output belongs before its input's place.
    private var resampled = (input: 0, output: 0)
    private var pending: [Float] = []
    private var flushed = 0
    private(set) var corrected = 0
    private let write: Write
    // A write failed and the file was closed; the rest of the track counts as lost.
    public private(set) var hasFailed = false

    public init(writingTo url: URL, sourceRate: Double, write: @escaping Write = { ExtAudioFileWrite($0, $1, $2) }) throws {
        pending.reserveCapacity(2 * Self.flushSamples)
        self.sourceRate = sourceRate
        self.write = write
        resampler = try Self.resampler(from: sourceRate)
        file = try SpeechAudio.createKeptFile(at: url)
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    public func retarget(to sourceRate: Double) throws {
        logConvertFailure()
        resampler = try Self.resampler(from: sourceRate)
        self.sourceRate = sourceRate
        resampled = (0, 0)
    }

    // `position` is where the first sample belongs, in seconds since the meeting started, paused time left out.
    // `hear` gets the same audio at the speech rate.
    public func append(
        _ samples: UnsafeBufferPointer<Float>, at position: Double, then hear: (UnsafeBufferPointer<Float>) -> Void = { _ in }
    ) {
        guard file != nil else { return }
        guard resampler != nil else {
            place(samples, at: position)
            hear(samples)
            return
        }
        guard let target = resampler?.input(frames: samples.count) else { return }
        for (index, sample) in samples.enumerated() { target[index] = sample }
        let held = Double(resampled.input) * Self.rate / sourceRate - Double(resampled.output)
        resampled.input += samples.count
        guard let output = resampler?.convert(), let channel = output.floatChannelData?[0] else { return }
        let converted = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        resampled.output += converted.count
        place(converted, at: position - held / Self.rate)
        hear(converted)
    }

    // Share of the track padded or cut to hold it to the meeting's clock: sound the source lost, or sent at a rate it did not report.
    public var correctedShare: Double {
        Double(corrected) / Double(max(length, 1))
    }

    // Pads or cuts the track to `duration` seconds and closes the file; throws when part of it never reached the disk.
    public func finish(at duration: Double) throws {
        let target = Int((duration * Self.rate).rounded())
        if length < target {
            addSilence(target - length)
        } else {
            let cut = min(length - target, pending.count)
            pending.removeLast(cut)
            corrected += cut
        }
        flush()
        if let file { ExtAudioFileDispose(file) }
        file = nil
        logConvertFailure()
        if hasFailed { throw TrackWriterError.writeFailed }
    }

    private func logConvertFailure() {
        guard let resampler, resampler.hasFailed else { return }
        Log.failure("meeting-track-convert", error: resampler.failure)
    }

    var length: Int { flushed + pending.count }

    // The microphone and the output device run on separate clocks, so each track is held to the meeting's clock here.
    private func place(_ samples: UnsafeBufferPointer<Float>, at position: Double) {
        let drift = Int((position * Self.rate).rounded()) - length
        var first = 0
        if drift > Self.toleranceSamples {
            addSilence(drift)
        } else if drift < -Self.toleranceSamples {
            first = min(-drift, samples.count)
            corrected += first
        }
        var rest = samples[first...]
        while !rest.isEmpty {
            let taken = rest.prefix(Self.flushSamples - pending.count)
            pending.append(contentsOf: taken)
            rest = rest.dropFirst(taken.count)
            if pending.count >= Self.flushSamples { flush() }
        }
    }

    private func addSilence(_ count: Int) {
        corrected += count
        var left = count
        while left > 0 {
            let taken = min(left, Self.flushSamples - pending.count)
            pending.append(contentsOf: repeatElement(0, count: taken))
            left -= taken
            if pending.count >= Self.flushSamples { flush() }
        }
    }

    // A plain write hands the audio to the system, which keeps it when the process dies.
    private func flush() {
        defer {
            flushed += pending.count
            pending.removeAll(keepingCapacity: true)
        }
        guard let file, !pending.isEmpty else { return }
        let status = pending.withUnsafeMutableBufferPointer { samples in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(samples.count * 4), mData: samples.baseAddress)
            )
            return write(file, UInt32(samples.count), &list)
        }
        guard status != noErr else { return }
        Log.failure("meeting-track-write")
        hasFailed = true
        corrected += pending.count
        ExtAudioFileDispose(file)
        self.file = nil
    }

    private static func resampler(from sourceRate: Double) throws -> Resampler? {
        guard sourceRate != rate else { return nil }
        guard let resampler = Resampler(from: sourceRate) else { throw RecorderError.noInput }
        return resampler
    }
}
