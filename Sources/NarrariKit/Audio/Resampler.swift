import AVFoundation

// Mono samples at a device's rate in, mono samples at the speech rate out, with buffers reused between calls.
// It never logs, because it runs on the audio thread; the owner logs `failure` once it is off that thread.
struct Resampler {
    private var converter: AVAudioConverter
    private var input: AVAudioPCMBuffer?
    private var output: AVAudioPCMBuffer?
    private(set) var hasFailed = false
    private(set) var failure: NSError?

    init?(from sampleRate: Double) {
        guard let converter = Self.converter(from: sampleRate) else { return nil }
        self.converter = converter
    }

    mutating func retarget(to sampleRate: Double) -> Bool {
        guard let converter = Self.converter(from: sampleRate) else { return false }
        self.converter = converter
        input = nil
        output = nil
        return true
    }

    // Buffers for calls of up to `frames`, made now so the audio thread's first calls allocate none.
    mutating func prepare(frames: Int) {
        _ = input(frames: frames)
        input?.frameLength = 0
        output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputCapacity(for: AVAudioFrameCount(frames)))
    }

    // Filled by the caller before convert(), so a device's samples never pass into state that a lock guards.
    mutating func input(frames: Int) -> UnsafeMutablePointer<Float>? {
        guard frames > 0 else { return nil }
        let count = AVAudioFrameCount(frames)
        if (input?.frameCapacity ?? 0) < count {
            input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: count)
        }
        input?.frameLength = count
        return input?.floatChannelData?[0]
    }

    // The result is reused by the next call.
    mutating func convert() -> AVAudioPCMBuffer? {
        guard let input, input.frameLength > 0 else { return nil }
        let capacity = outputCapacity(for: input.frameLength)
        if (output?.frameCapacity ?? 0) < capacity {
            output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        }
        defer { input.frameLength = 0 }
        guard let output else { return nil }
        guard Self.convert(input, with: converter, into: output, error: &failure) else {
            hasFailed = true
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    private func outputCapacity(for frames: AVAudioFrameCount) -> AVAudioFrameCount {
        AVAudioFrameCount((Double(frames) * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate).rounded(.up)) + 32
    }

    static func mono(at sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    private static func converter(from sampleRate: Double) -> AVAudioConverter? {
        guard let source = mono(at: sampleRate), let target = mono(at: SpeechAudio.sampleRate) else { return nil }
        return AVAudioConverter(from: source, to: target)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, into output: AVAudioPCMBuffer, error: inout NSError?
    ) -> Bool {
        var isSupplied = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if isSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            isSupplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error
    }
}
