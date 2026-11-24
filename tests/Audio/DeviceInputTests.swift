import CoreAudio
import NarrariKit
import Testing

struct DeviceInputTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let streams: [InputLayout.Stream]
        // One array of interleaved raw values per stream.
        let data: [[Double]]
        let mixed: [Float]
        var testDescription: String { name }
    }

    private static let float = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    private static let integer = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

    // The format a device reports for one input stream.
    private static func format(
        channels: UInt32, bits: UInt32, flags: AudioFormatFlags, id: AudioFormatID = kAudioFormatLinearPCM
    ) -> AudioStreamBasicDescription {
        let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let bytesPerFrame = (interleaved ? channels : 1) * bits / 8
        return AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: id, mFormatFlags: flags, mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
        )
    }

    private static func stream(channels: UInt32, bits: UInt32, flags: AudioFormatFlags) -> InputLayout.Stream {
        InputLayout.Stream(format(channels: channels, bits: bits, flags: flags))!
    }

    static let cases = [
        Case(name: "mono float", streams: [stream(channels: 1, bits: 32, flags: float)], data: [[0.5, -0.25]], mixed: [0.5, -0.25]),
        Case(
            name: "interleaved stereo float", streams: [stream(channels: 2, bits: 32, flags: float)],
            data: [[1, 0, 0.5, 0.5]], mixed: [0.5, 0.5]
        ),
        Case(
            name: "two mono streams", streams: [stream(channels: 1, bits: 32, flags: float), stream(channels: 1, bits: 32, flags: float)],
            data: [[1, 0.5], [0, 0.5]], mixed: [0.5, 0.5]
        ),
        Case(name: "16-bit integer", streams: [stream(channels: 1, bits: 16, flags: integer)], data: [[16_384, -32_768]], mixed: [0.5, -1])
    ]

    static let unreadable: [(String, AudioStreamBasicDescription)] = [
        ("big-endian", format(channels: 1, bits: 32, flags: float | kAudioFormatFlagIsBigEndian)),
        ("not PCM", format(channels: 1, bits: 32, flags: float, id: kAudioFormatMPEG4AAC)),
        ("24-bit integer", format(channels: 1, bits: 24, flags: integer)),
        ("unsigned integer", format(channels: 1, bits: 16, flags: kAudioFormatFlagIsPacked)),
        ("non-interleaved stereo", format(channels: 2, bits: 32, flags: float | kAudioFormatFlagIsNonInterleaved))
    ]

    @Test(arguments: cases)
    func every_input_channel_reaches_the_recording_as_one(_ test: Case) {
        let layout = InputLayout(sampleRate: 48_000, streams: test.streams)
        let list = AudioBufferList.allocate(maximumBuffers: test.streams.count)
        defer { free(list.unsafeMutablePointer) }
        for (index, (stream, values)) in zip(test.streams, test.data).enumerated() {
            list[index] = Self.buffer(values, stream)
        }
        defer { list.forEach { $0.mData?.deallocate() } }
        var mixed = [Float](repeating: .nan, count: test.mixed.count)

        let frames = layout.frames(in: list)
        mixed.withUnsafeMutableBufferPointer { layout.mix(list, from: 0, count: $0.count, into: $0.baseAddress!) }

        #expect(frames == test.mixed.count)
        #expect(mixed == test.mixed)
    }

    @Test(arguments: unreadable)
    func a_stream_format_the_mix_cannot_read_is_refused(_ name: String, _ format: AudioStreamBasicDescription) {
        #expect(InputLayout.Stream(format) == nil, Comment(rawValue: name))
    }

    @Test func buffers_in_another_layout_are_not_read() {
        let layout = InputLayout(sampleRate: 48_000, streams: [Self.stream(channels: 1, bits: 32, flags: Self.float)])
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = Self.buffer([1, 1], Self.stream(channels: 2, bits: 32, flags: Self.float))
        defer { list[0].mData?.deallocate() }

        #expect(layout.frames(in: list) == nil)
    }

    // A Bluetooth headset in a call runs at 16 kHz while the tap's stream in its aggregate still says 48 kHz, the tap's own rate.
    @Test func a_tap_is_read_alone_at_the_rate_its_aggregate_runs_at() throws {
        let microphone = Self.format(channels: 1, bits: 32, flags: Self.float)
        let tap = Self.format(channels: 2, bits: 32, flags: Self.float)
        let layout = try #require(InputLayout(sampleRate: 16_000, formats: [microphone, tap], reading: .last))
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = Self.buffer([1, 1, 1], Self.stream(channels: 1, bits: 32, flags: Self.float))
        list[1] = Self.buffer([0.5, 0.5, -0.5, -0.5], Self.stream(channels: 2, bits: 32, flags: Self.float))
        defer { list.forEach { $0.mData?.deallocate() } }
        var mixed: [Float] = [.nan, .nan]

        mixed.withUnsafeMutableBufferPointer { layout.mix(list, from: 0, count: 2, into: $0.baseAddress!) }

        #expect(layout.sampleRate == 16_000)
        #expect(layout.frames(in: list) == 2)
        #expect(mixed == [0.5, -0.5])
    }

    private static func buffer(_ values: [Double], _ stream: InputLayout.Stream) -> AudioBuffer {
        let raw: UnsafeMutableRawBufferPointer
        switch stream.sample {
        case .float32: raw = copy(values.map { Float($0) })
        case .int16: raw = copy(values.map { Int16($0) })
        case .int32: raw = copy(values.map { Int32($0) })
        }
        return AudioBuffer(mNumberChannels: UInt32(stream.channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
    }

    private static func copy<Value>(_ values: [Value]) -> UnsafeMutableRawBufferPointer {
        let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: values.count * MemoryLayout<Value>.stride, alignment: 16)
        values.withUnsafeBytes { raw.copyMemory(from: $0) }
        return raw
    }
}
