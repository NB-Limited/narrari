import AudioToolbox
import AVFoundation

// The audio the speech model takes, and the form history keeps it in.
public enum SpeechAudio {
    public static let sampleRate: Double = 16_000

    // The speech model refuses less than 0.3 s of audio.
    static let minimumSamples = Int(0.3 * sampleRate)

    // 16-bit mono at the speech rate, from the microphone or from a file.
    static var keptFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
    }

    // An empty kept file at `url`, taking mono Float samples at the speech rate.
    static func createKeptFile(at url: URL) throws -> ExtAudioFileRef {
        guard let kept = AVAudioFormat(settings: keptFileSettings), let client = Resampler.mono(at: sampleRate) else {
            throw RecorderError.startFailed
        }
        var file: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, kept.streamDescription, nil, AudioFileFlags.eraseFile.rawValue, &file)
            == noErr, let file
        else { throw RecorderError.startFailed }
        // The History and Meetings folders are the owner's alone already, so a recording goes ahead without this.
        do {
            try AppPaths.makeOwnerOnly(url)
        } catch {
            Log.failure("audio-file-owner-only", error: error)
        }
        let status = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            client.streamDescription
        )
        guard status == noErr else {
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.startFailed
        }
        return file
    }
}
