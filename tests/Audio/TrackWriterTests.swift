import AVFoundation
import NarrariKit
import Testing

struct TrackWriterTests {
    private let folder = TemporaryFolder()

    private func write(seconds: Double, at sampleRate: Double, to writer: TrackWriter) {
        let tone = (0..<Int(seconds * sampleRate)).map { Float(sin(Double($0) * 2 * .pi * 440 / sampleRate) * 0.25) }
        let part = Int(sampleRate / 10)
        for start in stride(from: 0, to: tone.count, by: part) {
            tone[start..<min(start + part, tone.count)].withUnsafeBufferPointer {
                writer.append($0, at: Double(start) / sampleRate)
            }
        }
    }

    // 22.05, 24 and 32 kHz are rates BlackHole does not offer, so the rig cannot play them.
    @Test(arguments: [22_050.0, 24_000, 32_000, 48_000])
    func a_track_is_kept_as_16_khz_mono_16_bit_at_its_pitch_whatever_rate_the_device_runs_at(rate: Double) throws {
        let url = folder.url.appending(path: "mic.caf")
        let writer = try TrackWriter(writingTo: url, sourceRate: rate)

        write(seconds: 3, at: rate, to: writer)
        try writer.finish(at: 3)

        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat.streamDescription.pointee
        #expect(format.mSampleRate == 16_000)
        #expect(format.mChannelsPerFrame == 1)
        #expect(format.mBitsPerChannel == 16)
        #expect(file.length == 48_000)
        #expect(writer.correctedShare < 0.01)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength))
        let crossings = zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(abs(Double(crossings) / 2 / 3 - 440) < 5)
    }

    @Test func a_write_the_disk_refuses_fails_the_track_and_the_rest_of_it_counts_as_lost() throws {
        let writer = try TrackWriter(writingTo: folder.url.appending(path: "mic.caf"), sourceRate: 16_000) { _, _, _ in kAudioFileUnspecifiedError }

        write(seconds: 3, at: 16_000, to: writer)

        #expect(writer.hasFailed)
        #expect(throws: TrackWriterError.writeFailed) { try writer.finish(at: 3) }
        #expect(writer.correctedShare == 1)
    }

    @Test func a_track_never_closed_still_opens_and_has_all_but_its_last_two_seconds() throws {
        let url = folder.url.appending(path: "system.caf")
        let writer = try TrackWriter(writingTo: url, sourceRate: 16_000)

        write(seconds: 10.5, at: 16_000, to: writer)

        let length = try AVAudioFile(forReading: url).length
        #expect(length >= 8 * 16_000 && length <= 10_500 * 16)
        withExtendedLifetime(writer) {}
    }

    // 16 kHz sent as 48 kHz, 320 samples each 20 ms, as a Bluetooth headset in a call did: two thirds of the track is padding.
    @Test func sound_sent_at_a_rate_other_than_the_one_reported_shows_as_corrected() throws {
        let honest = try TrackWriter(writingTo: folder.url.appending(path: "honest.caf"), sourceRate: 16_000)
        let mislabelled = try TrackWriter(writingTo: folder.url.appending(path: "mislabelled.caf"), sourceRate: 48_000)
        let cycle = [Float](repeating: 0.25, count: 320)

        for index in 0..<500 {
            cycle.withUnsafeBufferPointer { samples in
                [honest, mislabelled].forEach { $0.append(samples, at: Double(index) * 0.02) }
            }
        }
        try [honest, mislabelled].forEach { try $0.finish(at: 10) }

        #expect(honest.correctedShare < 0.01)
        #expect(abs(mislabelled.correctedShare - 2.0 / 3) < 0.02)
    }
}
