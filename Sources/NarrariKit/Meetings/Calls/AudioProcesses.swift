import CoreAudio
import Foundation

// One app's use of sound, as Core Audio reports it.
public struct AudioProcess: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(pid: pid_t, bundleID: String, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

// What to read of one app's process. The sound server spends close to a millisecond on each input or output read.
public struct AudioProcessReads: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let input = Self(rawValue: 1)
    public static let output = Self(rawValue: 2)
}

public protocol AudioProcessSource: Sendable {
    // Every app connected to Core Audio; an input or output `reads` does not ask of a process, given its pid and bundle ID, stays false.
    func processes(reading reads: (pid_t, String) -> AudioProcessReads) -> [AudioProcess]
    // `onChange` runs after an app starts or stops using sound, until unwatch. Core Audio tells of most such changes, not all.
    func watch(_ onChange: @escaping @Sendable () async -> Void)
    func unwatch()
}

// Every app connected to Core Audio. It notifies a process's running and devices, never its input state, and nothing at all
// when a process already playing on a device takes that device's input too (`narrari-dev meeting call-watch`).
public final class SystemAudioProcesses: AudioProcessSource, @unchecked Sendable {
    private static let list = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
    private static let changes = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyDevices].map { AudioDevices.address($0) }
    private static let inputDevices = AudioDevices.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    // Everything below is touched on `queue` only, where Core Audio also calls the listener.
    private let queue = DispatchQueue(label: "com.nb-limited.narrari.audio-processes")
    private var onChange: (@Sendable () async -> Void)?
    private var isListWatched = false
    private var watched: Set<AudioObjectID> = []
    private var refused: Set<AudioObjectID> = []
    private var identities: [AudioObjectID: (pid: pid_t, bundleID: String)] = [:]
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }

    public init() {}

    // A listener Core Audio refused is asked for again on each read, so a watch never rests on one that is missing.
    public func processes(reading reads: (pid_t, String) -> AudioProcessReads) -> [AudioProcess] {
        queue.sync {
            let current = AudioDevices.objects(in: Self.system, Self.list)
            if onChange != nil { follow(current) }
            identities = identities.filter { current.contains($0.key) }
            return current.compactMap { process in
                guard let identity = identity(of: process) else { return nil }
                let asked = reads(identity.pid, identity.bundleID)
                return AudioProcess(
                    pid: identity.pid, bundleID: identity.bundleID,
                    isRunningInput: asked.contains(.input) && Self.hasInputDevice(process) && Self.flag(kAudioProcessPropertyIsRunningInput, of: process),
                    isRunningOutput: asked.contains(.output) && Self.flag(kAudioProcessPropertyIsRunningOutput, of: process)
                )
            }
        }
    }

    public func watch(_ onChange: @escaping @Sendable () async -> Void) {
        queue.sync {
            guard self.onChange == nil else { return }
            self.onChange = onChange
            follow(AudioDevices.objects(in: Self.system, Self.list))
        }
    }

    public func unwatch() {
        queue.sync {
            guard onChange != nil else { return }
            onChange = nil
            if isListWatched { listen(false, to: Self.system, Self.list) }
            isListWatched = false
            watched.forEach(stopListening)
            watched = []
            refused = []
        }
    }

    private func changed() {
        if let onChange { Task { await onChange() } }
    }

    // A process that has gone takes its listeners with it, so a failed removal is expected.
    private func follow(_ current: [AudioObjectID]) {
        if !isListWatched {
            isListWatched = listen(true, to: Self.system, Self.list)
            if !isListWatched { Log.failure("audio-process-list-listener") }
        }
        let alive = Set(current)
        watched.subtracting(alive).forEach(stopListening)
        watched.formIntersection(alive)
        refused.formIntersection(alive)
        for process in alive.subtracting(watched) {
            if Self.changes.allSatisfy({ listen(true, to: process, $0) }) {
                watched.insert(process)
                refused.remove(process)
            } else {
                stopListening(to: process)
                if refused.insert(process).inserted { Log.failure("audio-process-listener") }
            }
        }
    }

    private func stopListening(to process: AudioObjectID) {
        Self.changes.forEach { listen(false, to: process, $0) }
    }

    @discardableResult
    private func listen(_ isOn: Bool, to object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        let status = isOn
            ? AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
            : AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        return status == noErr
    }

    private func identity(of process: AudioObjectID) -> (pid: pid_t, bundleID: String)? {
        if let known = identities[process] { return known }
        guard let pid: pid_t = Self.number(kAudioProcessPropertyPID, of: process) else { return nil }
        let identity = (pid, AudioDevices.string(kAudioProcessPropertyBundleID, of: process) ?? "")
        identities[process] = identity
        return identity
    }

    // A process taking input lists an input device; reading that costs the sound server a twentieth of the input state itself.
    private static func hasInputDevice(_ process: AudioObjectID) -> Bool {
        var address = inputDevices
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) != noErr || size > 0
    }

    private static func flag(_ selector: AudioObjectPropertySelector, of process: AudioObjectID) -> Bool {
        number(selector, of: process) == UInt32(1)
    }

    private static func number<Value: FixedWidthInteger>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> Value? {
        var address = AudioDevices.address(selector)
        var value: Value = 0
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
