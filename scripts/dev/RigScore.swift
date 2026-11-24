import Accelerate
import Foundation
import NarrariKit

// The rig's test sound: tones in half-second slots, each slot's pitch known, so a wrong rate shows as a wrong pitch.
enum RigSignal {
    static let slot = 0.5
    static let tones: [Double] = [300, 450, 650, 950, 1_400, 2_000, 2_900]
    static let amplitude: Float = 0.5

    static func pitch(ofSlot slot: Int) -> Double { tones[slot % tones.count] }

    static func tone(_ seconds: Double) -> Float {
        guard seconds >= 0 else { return 0 }
        let frequency = pitch(ofSlot: Int(seconds / slot))
        return amplitude * Float(sin(2 * .pi * frequency * seconds))
    }

    static func speech(_ samples: [Float]) -> @Sendable (Double) -> Float {
        { seconds in
            let place = seconds * SpeechAudio.sampleRate
            let index = Int(place)
            guard place >= 0, index + 1 < samples.count else { return 0 }
            let fraction = Float(place - Double(index))
            return samples[index] * (1 - fraction) + samples[index + 1] * fraction
        }
    }
}

struct TrackScore {
    var played = 0.0
    var correct = 0.0
    // Seconds inside the played span with no sound at all, counted in 10 ms blocks.
    var lost = 0.0
    var wrongPitchSlots = 0
    var levelDecibels = -Double.infinity
    // Where the sound landed against where the meeting's clock says it belongs, at the start and at the end.
    var offset: Double?
    var endOffset: Double?

    var drift: Double? { offset.flatMap { start in endOffset.map { $0 - start } } }
}

enum RigScore {
    private static let rate = SpeechAudio.sampleRate
    private static let search = 0.3
    private static let quiet: Float = 0.003

    static func tones(_ track: [Float], lead: Double, seconds: Double) -> TrackScore {
        var score = TrackScore(played: seconds)
        score.offset = offset(of: RigSignal.tone, in: track, near: lead, from: 0.25, length: 2)
        score.endOffset = offset(of: RigSignal.tone, in: track, near: lead, from: seconds - 2.25, length: 2)
        let shift = score.offset ?? 0
        score.lost = silentSeconds(track, from: lead + shift, seconds: seconds)
        var levels: [Float] = []
        for slot in 0..<Int(seconds / RigSignal.slot) {
            let from = Int(((lead + shift + Double(slot) * RigSignal.slot + 0.1) * rate).rounded())
            let to = from + Int(0.3 * rate)
            guard from >= 0, to <= track.count else { continue }
            let part = Array(track[from..<to])
            let level = rms(part)
            guard level > quiet else { continue }
            let expected = RigSignal.pitch(ofSlot: slot)
            if abs(pitch(part) - expected) / expected < 0.03 {
                score.correct += RigSignal.slot
                levels.append(level)
            } else {
                score.wrongPitchSlots += 1
            }
        }
        if let median = levels.sorted()[safe: levels.count / 2] { score.levelDecibels = 20 * log10(Double(median)) }
        return score
    }

    static func speech(_ track: [Float], lead: Double, reference: [Float]) -> TrackScore {
        let seconds = Double(reference.count) / rate
        var score = TrackScore(played: seconds)
        let signal = RigSignal.speech(reference)
        score.offset = offset(of: signal, in: track, near: lead, from: 0.5, length: min(3, seconds - 1))
        score.endOffset = offset(of: signal, in: track, near: lead, from: max(0.5, seconds - 3.5), length: min(3, seconds - 1))
        let from = max(0, Int(lead * rate))
        let level = rms(Array(track[min(from, track.count)..<min(from + reference.count, track.count)]))
        score.levelDecibels = 20 * log10(Double(max(level, 1e-9)))
        return score
    }

    // The lag, within `search` seconds, at which the track best matches the signal's stretch from `from` for `length` seconds.
    static func offset(of signal: (Double) -> Float, in track: [Float], near lead: Double, from: Double, length: Double) -> Double? {
        let reference = (0..<Int(length * rate)).map { signal(from + Double($0) / rate) }
        let lags = Int(search * rate)
        let begin = Int(((lead + from) * rate).rounded()) - lags
        guard begin >= 0, begin + reference.count + 2 * lags <= track.count, rms(reference) > quiet else { return nil }
        let window = Array(track[begin..<begin + reference.count + 2 * lags])
        guard rms(window) > quiet else { return nil }
        var products = [Float](repeating: 0, count: 2 * lags + 1)
        vDSP_conv(window, 1, reference, 1, &products, 1, vDSP_Length(products.count), vDSP_Length(reference.count))
        var best: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(products, 1, &best, &index, vDSP_Length(products.count))
        return best > 0 ? Double(Int(index) - lags) / rate : nil
    }

    private static func silentSeconds(_ track: [Float], from start: Double, seconds: Double) -> Double {
        let block = Int(0.01 * rate)
        let first = max(0, Int((start * rate).rounded()))
        let end = min(track.count, first + Int(seconds * rate))
        let silent = stride(from: first, to: end - block + 1, by: block).filter { rms(Array(track[$0..<$0 + block])) <= quiet }
        return Double(silent.count) * 0.01 + Double(max(0, first + Int(seconds * rate) - end)) / rate
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    private static func pitch(_ samples: [Float]) -> Double {
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(samples.count) / rate)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
