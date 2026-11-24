import Foundation

// A track going wrong while it records, as the meeting bar tells it.
public struct RecordingTrouble: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case stopped
        // Sound comes, but much of it is padded or cut, or it comes at a rate other than the one reported.
        case poor
    }

    public let track: TranscriptSegment.Track
    public let kind: Kind

    public init(track: TranscriptSegment.Track, kind: Kind) {
        self.track = track
        self.kind = kind
    }

    public var message: String {
        switch (track, kind) {
        case (.mic, .stopped): "Your microphone stopped recording"
        case (.mic, .poor): "Your microphone is not recording well"
        case (.system, .stopped): "Other people's sound stopped recording"
        case (.system, .poor): "Other people's sound is not recording well"
        }
    }
}

// One track's live checks, on the capture's queue, in host seconds. The rig measured a rate change pausing a device 0.6 s,
// and padding or cutting over 30 s at 0 to 2% steady, 14% for six changes in 12 s and 67% on the call that was lost.
struct TrackHealth {
    static let stallSeconds = 3.0
    static let retrySeconds = 10.0
    static let rateSeconds = 10.0
    static let rateTolerance = 0.05
    // A longer pause between two buffers is the stall check's, not a rate.
    static let longestStep = 0.25
    static let shareSeconds = 30.0
    static let shortestShareSeconds = 10.0
    static let poorShare = 0.25
    static let clearSeconds = 10.0
    static let clearShare = 0.05

    private(set) var trouble: RecordingTrouble.Kind?
    private(set) var hasDelivered = false

    private var since: Double
    private var stalls = 0
    private var rate: Double?
    private var isFresh = true
    private var step: (time: Double, frames: Int)?
    private var rateFrames = 0
    private var rateSpan = 0.0
    private var rateVerdict: Bool?
    private var isRebuiltForRate = false
    private var isRateWrong = false
    private var written: [(time: Double, length: Int, corrected: Int)] = []
    private var isSharePoor = false

    init(at time: Double, rate: Double?) {
        since = time
        self.rate = rate
    }

    // A new engine, or none when nil. What the rebuild cost is not held against it.
    mutating func restarted(at time: Double, rate: Double?) {
        since = time
        self.rate = rate
        isFresh = true
        step = nil
        rateFrames = 0
        rateSpan = 0
        rateVerdict = nil
        written = []
    }

    mutating func delivered(_ frames: Int, at time: Double) {
        hasDelivered = true
        isFresh = false
        since = max(since, time)
        stalls = 0
        if let last = step, time == last.time {
            step = (time, last.frames + frames)
            return
        }
        if let last = step, time > last.time, time - last.time < Self.longestStep {
            rateFrames += last.frames
            rateSpan += time - last.time
        }
        step = (time, frames)
        guard rateSpan >= Self.rateSeconds, let rate else { return }
        rateVerdict = abs(Double(rateFrames) / rateSpan / rate - 1) > Self.rateTolerance
        rateFrames = 0
        rateSpan = 0
    }

    // True when the engine should be built again.
    mutating func check(at now: Double, length: Int, corrected: Int) -> Bool {
        defer { updateTrouble() }
        if now - since >= (stalls < 2 ? Self.stallSeconds : Self.retrySeconds) {
            stalls += 1
            since = now
            return true
        }
        if let isWrong = rateVerdict {
            rateVerdict = nil
            if !isWrong {
                isRebuiltForRate = false
                isRateWrong = false
            } else if !isRebuiltForRate {
                isRebuiltForRate = true
                return true
            } else {
                isRateWrong = true
            }
        }
        judgeShare(at: now, length: length, corrected: corrected)
        return false
    }

    private mutating func judgeShare(at now: Double, length: Int, corrected: Int) {
        guard !isFresh else { return }
        written.append((now, length, corrected))
        if let keep = written.lastIndex(where: { $0.time <= now - Self.shareSeconds }) { written.removeFirst(keep) }
        if let whole = share(over: Self.shareSeconds, at: now), whole.seconds >= Self.shortestShareSeconds, whole.share >= Self.poorShare {
            isSharePoor = true
        } else if isSharePoor, let recent = share(over: Self.clearSeconds, at: now), recent.seconds >= Self.clearSeconds - 1,
                  recent.share < Self.clearShare {
            isSharePoor = false
        }
    }

    // The share padded or cut over about the last `seconds`, and how many seconds of track that was.
    private func share(over seconds: Double, at now: Double) -> (share: Double, seconds: Double)? {
        guard let last = written.last, let from = written.last(where: { $0.time <= now - seconds }) ?? written.first else { return nil }
        let samples = last.length - from.length
        guard samples > 0 else { return nil }
        return (Double(last.corrected - from.corrected) / Double(samples), Double(samples) / SpeechAudio.sampleRate)
    }

    private mutating func updateTrouble() {
        trouble = stalls >= 2 ? .stopped : isRateWrong || isSharePoor ? .poor : nil
    }
}
