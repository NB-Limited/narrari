import CoreAudio
import Foundation
import NarrariKit
import Synchronization

// Sits between the recorder and the product's engines and counts what each engine delivers, so a failed row says whether the
// recorder's input stopped or the rig's player did. Every call goes through to the product unchanged.
final class RigWatch: AudioInputs, SystemSoundSource, Sendable {
    enum Side: String {
        case microphone = "mic"
        case system
    }

    private let inputs: any AudioInputs
    private let system: any SystemSoundSource
    private let fault: RigScenario.Fault?
    private let start: Double
    private let engines = Mutex<[WatchedEngine]>([])

    init(inputs: any AudioInputs, system: any SystemSoundSource, fault: RigScenario.Fault?, start: Double) {
        self.inputs = inputs
        self.system = system
        self.fault = fault
        self.start = start
    }

    func current(chosenUID: String, prefersBuiltIn: Bool) -> AudioObjectID? {
        inputs.current(chosenUID: chosenUID, prefersBuiltIn: prefersBuiltIn)
    }

    func name(of device: AudioObjectID) -> String? { inputs.name(of: device) }

    func makeEngine(for device: AudioObjectID, onChange: @escaping @Sendable () -> Void) -> any InputEngine {
        watch(inputs.makeEngine(for: device, onChange: onChange), side: .microphone)
    }

    func makeEngine(onChange: @escaping @Sendable () -> Void) -> any InputEngine {
        watch(system.makeEngine(onChange: onChange), side: .system)
    }

    // One line per engine: its rate, frames against that rate, its longest pause between two buffers, and how much of what it
    // delivered was silence, which is the loopback device's or the player's doing, not the recorder's.
    func lines(since start: Double) -> [String] {
        engines.withLock { $0.map { $0.line(since: start) } }
    }

    func silentSeconds(of side: Side) -> Double {
        engines.withLock { $0.filter { $0.side == side }.reduce(0) { $0 + $1.silentSeconds } }
    }

    private func watch(_ engine: any InputEngine, side: Side) -> any InputEngine {
        engines.withLock { engines in
            let isFirst = !engines.contains { $0.side == side }
            let applies = switch fault {
            case .freezes(let sides, let at): sides.contains(side) && hostSeconds() < start + at
            case .reports(let faulty, _): faulty == side && isFirst
            case nil: false
            }
            let watched = WatchedEngine(engine, side: side, fault: applies ? fault : nil, start: start)
            engines.append(watched)
            return watched
        }
    }
}

private final class WatchedEngine: InputEngine, Sendable {
    private struct Count {
        var started: Double?
        var stopped: Double?
        var first: Double?
        var last: Double?
        var frames = 0
        var silentFrames = 0
        var longestGap = 0.0
    }

    let side: RigWatch.Side
    private let engine: any InputEngine
    private let fault: RigScenario.Fault?
    private let start: Double
    private let count = Mutex(Count())

    init(_ engine: any InputEngine, side: RigWatch.Side, fault: RigScenario.Fault?, start: Double) {
        self.engine = engine
        self.side = side
        self.fault = fault
        self.start = start
    }

    var sampleRate: Double? {
        if case .reports(_, let rate) = fault { return rate }
        return engine.sampleRate
    }

    func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) throws {
        count.withLock { $0.started = hostSeconds() }
        try engine.start { [self] samples, hostTime in
            let now = hostSeconds()
            self.count.withLock { count in
                if let last = count.last { count.longestGap = max(count.longestGap, now - last) }
                count.first = count.first ?? now
                count.last = now
                count.frames += samples.count
                if !samples.contains(where: { abs($0) > 1e-6 }) { count.silentFrames += samples.count }
            }
            if case .freezes(_, let at) = fault, now >= start + at { return }
            feed(samples, hostTime)
        }
    }

    func stop() {
        count.withLock { $0.stopped = hostSeconds() }
        engine.stop()
    }

    var silentSeconds: Double {
        Double(count.withLock { $0.silentFrames }) / max(sampleRate ?? 1, 1)
    }

    func line(since start: Double) -> String {
        let count = count.withLock { $0 }
        let at = { (time: Double?) in time.map { String(format: "%.2f", $0 - start) } ?? "-" }
        let span = (count.last ?? 0) - (count.first ?? 0)
        let delivered = span > 0 ? String(format: "%.0f", Double(count.frames) / span) : "-"
        let silent = silentSeconds
        return "\(side): rate \(Int(sampleRate ?? 0)) Hz, started \(at(count.started)) s, first buffer \(at(count.first)) s, "
            + "last \(at(count.last)) s, stopped \(at(count.stopped)) s, \(count.frames) frames, \(delivered) per s, "
            + String(format: "longest gap %.2f s, silent %.1f s", count.longestGap, silent)
    }
}
