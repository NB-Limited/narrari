import Foundation
import NarrariKit
import OSLog

struct RigScenario {
    enum Tracks {
        case both
        case microphone
        case system
    }

    enum Sound {
        case tones(seconds: Double)
        case speech
    }

    // The output the tap's device is built on; the player always plays into the loopback device.
    enum Tap {
        case loopback
        case otherDevice
        case multiOutput
    }

    // Made by the rig at the recorder's boundary, on the product's real engines.
    enum Fault {
        // Every engine of those tracks running at that moment stops handing over sound; those the recorder builds later are sound.
        case freezes([RigWatch.Side], at: Double)
        // The first engine only, as the tap did on the call that was lost.
        case reports(RigWatch.Side, rate: Double)

        var sides: [RigWatch.Side] {
            switch self {
            case .freezes(let sides, _): sides
            case .reports(let side, _): [side]
            }
        }

        // The recorder's 3 s wait, up to 1 s to its next check, and building a tap again, which took up to 1.5 s on a busy Mac.
        var allowedLoss: Double {
            switch self {
            case .freezes: 5.5
            case .reports: 12.5
            }
        }
    }

    let name: String
    var rate = 48_000.0
    // Seconds after the signal starts, and the rate the device moves to then.
    var changes: [(at: Double, rate: Double)] = []
    var channels = 2
    var tracks = Tracks.both
    var tap = Tap.loopback
    var fault: Fault?
    var sound = Sound.tones(seconds: 10)

    static func all(isQuick: Bool) -> [Self] {
        var list = [8_000.0, 16_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000].map {
            Self(name: "\(Self.kilohertz($0)) kHz", rate: $0)
        }
        list += [
            Self(name: "1 channel", channels: 1),
            Self(name: "16 channels", channels: 16),
            Self(name: "48 to 16 kHz mid-way", changes: [(7, 16_000)], sound: .tones(seconds: 14)),
            Self(name: "16 to 48 kHz mid-way", rate: 16_000, changes: [(7, 48_000)], sound: .tones(seconds: 14)),
            Self(
                name: "6 changes in 12 s", changes: [(3, 16_000), (5, 44_100), (7, 16_000), (9, 48_000), (11, 8_000), (13, 48_000)],
                sound: .tones(seconds: 16)
            ),
            Self(name: "microphone only", tracks: .microphone),
            Self(name: "system only", tracks: .system),
            Self(name: "call on another speaker", tap: .otherDevice),
            Self(name: "multi-output device", tap: .multiOutput),
            Self(name: "5 s meeting", sound: .tones(seconds: 5)),
            Self(name: "speech", sound: .speech),
            Self(name: "speech, 1 of 16 channels", channels: 1, sound: .speech),
            Self(name: "speech, 48 to 16 kHz", changes: [(8, 16_000)], sound: .speech),
            Self(name: "tap frozen mid-way", fault: .freezes([.system], at: 5), sound: .tones(seconds: 16)),
            Self(name: "microphone frozen mid-way", fault: .freezes([.microphone], at: 5), sound: .tones(seconds: 16)),
            Self(
                name: "both frozen after 48 to 16 kHz", changes: [(5, 16_000)], fault: .freezes([.microphone, .system], at: 7),
                sound: .tones(seconds: 16)
            ),
            Self(name: "tap at a wrong rate", rate: 16_000, fault: .reports(.system, rate: 48_000), sound: .tones(seconds: 22))
        ]
        if !isQuick { list.append(Self(name: "30 min", sound: .tones(seconds: 1_800))) }
        return list
    }

    static func kilohertz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1_000) == 0 ? String(Int(rate / 1_000)) : String(format: "%.1f", rate / 1_000)
    }
}

// What the recorder said about one recording in its own log: lines with fixed names and counts only.
struct RecorderReport {
    var corrected: [String: Int] = [:]
    var reconnects = 0
    var rebuilt: Set<String> = []
    var told: [String] = []
    var failures: [String] = []

    static func read(since date: Date) -> Self {
        var report = Self()
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: date))
        else { return report }
        // The store's position is only where reading starts, so an earlier scenario's lines would come along.
        for case let entry as OSLogEntryLog in entries where entry.date >= date {
            let words = entry.composedMessage.split(separator: " ").map(String.init)
            switch words.first {
            case "count" where words.count == 3 && words[1].hasSuffix("-corrected-percent"):
                report.corrected[words[1].contains("microphone") ? "mic" : "system"] = Int(words[2])
            case "event" where words.count == 2 && words[1] == "meeting-input-reconnected":
                report.reconnects += 1
            case "event" where words.count == 2 && words[1].hasSuffix("-rebuilt"):
                report.rebuilt.insert(words[1].contains("microphone") ? "mic" : "system")
            case "event" where words.count == 2 && words[1].contains("-told-"):
                report.told.append(words[1])
            case "failure" where words.count >= 2:
                report.failures.append(words[1])
            default:
                break
            }
        }
        return report
    }
}

struct RigRow {
    let scenario: String
    let track: String
    let score: TrackScore
    let corrected: Int?
    let words: (heard: Int, spoken: Int)?
    let isSpeech: Bool
    let paused: Double
    // How far the microphone track sits from the system track; on the microphone's row when both carry the sound.
    var apart: Double?

    // A device that paused with no change makes the row unsound; what the device lost itself is not the recorder's.
    // `allowed` is what a fault the rig made may cost before the recorder builds the engine again.
    func faults(changes: Int, allowed: Double = 0) -> [String] {
        var faults: [String] = []
        if changes == 0, paused > 0.05 { faults.append("device paused") }
        // Building the tap again costs 0.09 s on an idle Mac and up to 0.14 s on a loaded one, measured over six changes.
        if !isSpeech, score.lost - paused > 0.15 * Double(changes) + 0.05 + allowed { faults.append("sound lost") }
        if !isSpeech, Double(score.wrongPitchSlots) > Double(2 * changes) + allowed / RigSignal.slot || score.correct == 0 {
            faults.append("pitch")
        }
        // A fault the rig made may spoil the start, so a faulty track is held to where its sound sits once repaired.
        let offset = allowed > 0 ? score.endOffset : score.offset
        if let offset { if abs(offset) > 0.05 { faults.append("offset") } } else { faults.append("not found") }
        if allowed == 0, let drift = score.drift, abs(drift) > 0.03 { faults.append("drift") }
        if let apart, abs(apart) > 0.03 { faults.append("apart") }
        if changes == 0, allowed == 0, let corrected, corrected > 2 { faults.append("corrected") }
        if let words, Double(words.heard) < 0.9 * Double(words.spoken) { faults.append("words") }
        return faults
    }
}
