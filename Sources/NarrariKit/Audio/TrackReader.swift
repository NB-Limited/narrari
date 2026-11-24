import AVFoundation

// Reads a meeting track as mono Float at the speech rate, a block at a time, so an hour never sits in memory.
public final class TrackReader {
    private let file: AVAudioFile
    private var buffer: AVAudioPCMBuffer?

    public init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == SpeechAudio.sampleRate, format.channelCount == 1 else { throw AudioFileError.unreadable }
    }

    public var sampleCount: Int { Int(file.length) }

    // The next `count` samples, fewer at the end, nil once the track is done.
    public func next(_ count: Int) throws -> [Float]? {
        guard file.framePosition < file.length else { return nil }
        if buffer.map({ $0.frameCapacity < AVAudioFrameCount(count) }) ?? true {
            buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        }
        guard let buffer else { throw AudioFileError.unreadable }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
