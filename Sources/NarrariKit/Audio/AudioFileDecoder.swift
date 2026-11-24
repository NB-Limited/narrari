import AVFoundation

public enum AudioFileError: Error, Equatable {
    case unreadable
    case noAudioTrack
    case tooLong(hours: Double)

    public var message: String {
        switch self {
        case .unreadable: "This file can't be read. Use an audio or video file, such as M4A, MP3, WAV, FLAC, MP4 or MOV."
        case .noAudioTrack: "This file has no sound to transcribe."
        case .tooLong(let hours):
            """
            This file is \(hours.formatted(.number.precision(.fractionLength(1)))) hours long. \
            Narrari transcribes files up to \(Int(AudioFileDecoder.maximumDuration / 3600)) hours.
            """
        }
    }
}

public enum AudioFileDecoder {
    // A file chosen from outside is refused past this; a meeting's own tracks have no limit.
    public static let maximumDuration: TimeInterval = 4 * 60 * 60

    public static func samples(from url: URL) async throws -> [Float] {
        let source = try await Source(url: url, upTo: maximumDuration)
        var samples: [Float] = []
        samples.reserveCapacity(Int(source.duration * SpeechAudio.sampleRate))
        while let block = try source.next() { samples += block }
        return samples
    }

    // Streams to a meeting track, so a long recording never sits in memory. Returns its length in seconds.
    public static func writeTrack(from url: URL, to track: URL) async throws -> Double {
        let source = try await Source(url: url, upTo: maximumDuration)
        let writer = try TrackWriter(writingTo: track, sourceRate: SpeechAudio.sampleRate)
        var samples = 0
        while let block = try source.next() {
            try Task.checkCancellation()
            block.withUnsafeBufferPointer { writer.append($0, at: Double(samples) / SpeechAudio.sampleRate) }
            samples += block.count
        }
        let seconds = Double(samples) / SpeechAudio.sampleRate
        writer.finish(at: seconds)
        return seconds
    }

    // The date the recording carries inside, else the file's creation date. A QuickTime header with no date reads as 1904.
    public static func recordingDate(of url: URL) async -> Date? {
        guard url.isFileURL else { return nil }
        if let item = try? await AVURLAsset(url: url).load(.creationDate), let date = try? await item.load(.dateValue),
           date > Date(timeIntervalSince1970: 0) {
            return date
        }
        return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private static func copy(_ block: CMBlockBuffer, _ byteCount: Int, to destination: UnsafeMutableRawPointer) throws {
        let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: destination)
        guard status == kCMBlockBufferNoErr else { throw AudioFileError.unreadable }
    }

    final class Source {
        let duration: TimeInterval
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput

        init(url: URL, upTo limit: TimeInterval?) async throws {
            // AVFoundation would fetch a web address itself; only a file on this Mac is read.
            guard url.isFileURL else { throw AudioFileError.unreadable }
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
                throw AudioFileError.unreadable
            }
            guard let track = tracks.first else { throw AudioFileError.noAudioTrack }

            duration = try await asset.load(.duration).seconds
            if let limit, duration > limit { throw AudioFileError.tooLong(hours: duration / 3600) }

            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: SpeechAudio.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            guard reader.startReading() else { throw AudioFileError.unreadable }
        }

        deinit {
            if reader.status == .reading { reader.cancelReading() }
        }

        func next() throws -> [Float]? {
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(block)
                guard byteCount > 0 else { continue }
                var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                try samples.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress else { throw AudioFileError.unreadable }
                    try copy(block, byteCount, to: base)
                }
                return samples
            }
            guard reader.status == .completed else { throw AudioFileError.unreadable }
            return nil
        }
    }
}
