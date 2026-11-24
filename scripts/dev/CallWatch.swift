import CoreAudio
import Darwin
import Foundation
import NarrariKit

// Runs the real SystemAudioProcesses while a child takes and lets go of BlackHole's input as a call app does, beside a 50 ms
// poll of Core Audio's own answer; tells which changes no notice told, whether the source's cheap read disagreed, and what a recheck costs.
func callWatch() async throws -> Bool {
    guard let loopback = RigDevice(uid: RigDevice.loopbackUID) else { throw RigError.refused("BlackHole 16ch is not installed") }
    let start = ContinuousClock.now
    let say: @Sendable (String) -> Void = { print(String(format: "%7.3f  ", seconds(since: start)) + $0) }
    let early = try CallHolder(uid: loopback.uid)
    try await Task.sleep(for: .milliseconds(500))
    let watch = CallWatch(say: say)
    watch.start()
    let poll = Task { await watch.poll() }
    let rate = loopback.rate
    let other = rate == 48_000 ? 44_100.0 : 48_000.0
    try await callSteps(early, say, [
        ("a child alive before the watch takes input", ["take"]),
        ("it lets go", ["release"]),
        ("it takes, lets go and takes again within a second", ["take", "release", "take"])
    ])
    say("STEP BlackHole's rate changes while it holds, then goes back")
    try await loopback.set(rate: other)
    try await Task.sleep(for: .seconds(2))
    try await loopback.set(rate: rate)
    try await Task.sleep(for: .seconds(2))
    try await callSteps(early, say, [("it lets go and quits", ["release", "quit"])])
    try await callSteps(try CallHolder(uid: loopback.uid), say, [
        ("a child born after the watch takes input", ["take"]),
        ("it closes its input and opens a new one", ["close", "take"]),
        ("it lets go and plays only", ["close", "play"]),
        ("while playing it takes input on the same device", ["take"]),
        ("it lets go of the input and keeps playing", ["close"]),
        ("it stops playing and takes input through a private aggregate", ["stop-play", "aggregate"]),
        ("it quits holding the aggregate", ["quit"])
    ])
    poll.cancel()
    await poll.value
    watch.stop()
    let isSound = watch.report()
    callCost(say)
    return isSound
}

private func callSteps(_ holder: CallHolder, _ say: @Sendable (String) -> Void, _ steps: [(String, [String])]) async throws {
    for (line, commands) in steps {
        say("STEP " + line)
        for command in commands {
            try holder.send(command)
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .seconds(2))
    }
}

// A recheck between calls: every app read for input.
private func callCost(_ say: @Sendable (String) -> Void) {
    let source = SystemAudioProcesses()
    let rounds = 200
    let server = serverSeconds()
    let own = ownSeconds()
    let start = ContinuousClock.now
    for _ in 0..<rounds { _ = source.processes { _, _ in .input } }
    let wall = seconds(since: start) / Double(rounds)
    let serverEach = (serverSeconds() - server) / Double(rounds)
    let ownEach = (ownSeconds() - own) / Double(rounds)
    let count = source.processes { _, _ in [] }.count
    say(String(
        format: "recheck of %d processes: %.2f ms wall, %.2f ms CPU here, %.2f ms in the sound server; every 2 s, %.1f s and %.1f s of CPU an hour",
        count, wall * 1_000, ownEach * 1_000, serverEach * 1_000, ownEach * 1_800, serverEach * 1_800
    ))
}

private func ownSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let times = [usage.ru_utime, usage.ru_stime]
    return times.reduce(0) { $0 + Double($1.tv_sec) + Double($1.tv_usec) / 1e6 }
}

// The sound server's CPU time so far, from ps, which reads it for any process.
private func serverSeconds() -> Double {
    func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try? process.run()
        process.waitUntilExit()
        let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let pid = run("/usr/bin/pgrep", ["-x", "coreaudiod"])
    let parts = run("/bin/ps", ["-o", "time=", "-p", pid]).split(separator: ":").compactMap { Double($0) }
    return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
}

// A child that holds BlackHole's input on command, with nothing else of its own on the sound server.
func callHold(uid: String) throws {
    guard let device = RigDevice(uid: uid) else { throw RigError.refused("no such device") }
    var input: AudioDeviceIOProcID?
    var player: AudioDeviceIOProcID?
    func open(on id: AudioObjectID) -> AudioDeviceIOProcID? {
        var made: AudioDeviceIOProcID?
        return AudioDeviceCreateIOProcIDWithBlock(&made, id, nil) { _, _, _, _, _ in } == noErr ? made : nil
    }
    func close(_ proc: inout AudioDeviceIOProcID?) {
        guard let made = proc else { return }
        AudioDeviceStop(device.id, made)
        AudioDeviceDestroyIOProcID(device.id, made)
        proc = nil
    }
    print("ready")
    fflush(stdout)
    while let line = readLine() {
        switch line {
        case "take":
            if input == nil { input = open(on: device.id) }
            if let input { AudioDeviceStart(device.id, input) }
        case "release": if let input { AudioDeviceStop(device.id, input) }
        case "close": close(&input)
        case "play":
            guard player == nil, let made = open(on: device.id) else { break }
            if !playsOnly(made, on: device.id) { FileHandle.standardError.write(Data("child: its input streams stayed on\n".utf8)) }
            AudioDeviceStart(device.id, made)
            player = made
        case "stop-play": close(&player)
        case "aggregate":
            let description: [String: Any] = [
                kAudioAggregateDeviceUIDKey: "narrari-call-watch-\(getpid())", kAudioAggregateDeviceNameKey: "Narrari call watch",
                kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]]
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate) == noErr, let made = open(on: aggregate) else { break }
            AudioDeviceStart(aggregate, made)
        default: return
        }
    }
}

// Turns the proc's input streams off, so it only plays.
private func playsOnly(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
    let usage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { usage.deallocate() }
    usage.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, usage) == noErr else { return false }
    let streams = Int(usage.load(fromByteOffset: 8, as: UInt32.self))
    for index in 0..<streams { usage.storeBytes(of: UInt32(0), toByteOffset: 12 + 4 * index, as: UInt32.self) }
    return AudioObjectSetPropertyData(device, &address, 0, nil, size, usage) == noErr
}

private final class CallHolder {
    private let process = Process()
    private let input = Pipe()

    init(uid: String) throws {
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["meeting", "call-hold", uid]
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        guard output.fileHandleForReading.availableData.starts(with: Data("ready".utf8)) else { throw RigError.player("holder did not start") }
    }

    func send(_ command: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        if command == "quit" { process.waitUntilExit() }
    }
}

// The children's input and output as the source reads them on each notice, against Core Audio's own answer polled every 50 ms.
private final class CallWatch: @unchecked Sendable {
    private struct Seen {
        let at: Double
        let state: [pid_t: String]
    }

    private let source = SystemAudioProcesses()
    private let say: @Sendable (String) -> Void
    private let lock = NSLock()
    private var notices: [Seen] = []
    private var polls: [Seen] = []
    private var disagreements = 0

    init(say: @escaping @Sendable (String) -> Void) { self.say = say }

    func start() {
        source.watch { [weak self] in self?.noticed() }
    }

    func stop() { source.unwatch() }

    func poll() async {
        var last: [pid_t: String] = [:]
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            let truth = Self.children(Self.raw())
            let read = Self.children(source.processes { pid, _ in Self.isChild(pid) ? [.input, .output] : [] })
            let isSettled = Self.children(Self.raw()) == truth
            lock.withLock {
                if isSettled, read != truth {
                    disagreements += 1
                    say("DISAGREE source " + Self.describe(read) + ", Core Audio " + Self.describe(truth))
                }
                guard truth != last else { return }
                last = truth
                polls.append(Seen(at: hostSeconds(), state: truth))
                say("POLL   " + Self.describe(truth))
            }
        }
    }

    // A polled change is missed when no notice from 100 ms before it to 1 s after read that same state. A disagreement counts
    // only when Core Audio gave the same answer just before and just after the source's read.
    func report() -> Bool {
        lock.withLock {
            let missed = polls.filter { poll in !notices.contains { $0.state == poll.state && $0.at > poll.at - 0.1 && $0.at < poll.at + 1 } }
            say("\(notices.count) notices, \(polls.count) changes, \(missed.count) told by no notice, \(disagreements) cheap reads that disagreed")
            return disagreements == 0
        }
    }

    private func noticed() {
        let state = Self.children(source.processes { pid, _ in Self.isChild(pid) ? [.input, .output] : [] })
        let truth = Self.children(Self.raw())
        lock.withLock {
            notices.append(Seen(at: hostSeconds(), state: state))
            say("NOTICE " + Self.describe(state) + (truth == state ? "" : ", Core Audio a moment later " + Self.describe(truth)))
        }
    }

    private static func children(_ processes: [AudioProcess]) -> [pid_t: String] {
        let states = processes.filter { isChild($0.pid) }.map { ($0.pid, "in \($0.isRunningInput ? 1 : 0) out \($0.isRunningOutput ? 1 : 0)") }
        return Dictionary(states) { first, _ in first }
    }

    // Core Audio's answer with no filter in front of it.
    private static func raw() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard let pid = number(kAudioProcessPropertyPID, of: object) else { return nil }
            return AudioProcess(
                pid: pid_t(pid), bundleID: "", isRunningInput: number(kAudioProcessPropertyIsRunningInput, of: object) == 1,
                isRunningOutput: number(kAudioProcessPropertyIsRunningOutput, of: object) == 1
            )
        }
    }

    private static func number(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func isChild(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return info.pbi_ppid == UInt32(getpid())
    }

    private static func describe(_ state: [pid_t: String]) -> String {
        state.isEmpty ? "no child" : state.sorted { $0.key < $1.key }.map { "pid \($0.key) \($0.value)" }.joined(separator: "; ")
    }
}
