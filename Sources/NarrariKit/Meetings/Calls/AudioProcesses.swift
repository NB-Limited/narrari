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

public protocol AudioProcessSource: Sendable {
    func processes() -> [AudioProcess]
    // `onChange` runs after an app starts or stops using sound, until unwatch.
    func watch(_ onChange: @escaping @Sendable () async -> Void)
    func unwatch()
}

// Every app connected to Core Audio, from the process list and each process's input and output state.
public final class SystemAudioProcesses: AudioProcessSource, @unchecked Sendable {
    private static let list = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
    private static let states = [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput].map { AudioDevices.address($0) }
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    // Everything below is touched on `queue` only, where Core Audio also calls the listener.
    private let queue = DispatchQueue(label: "com.nb-limited.narrari.audio-processes")
    private var onChange: (@Sendable () async -> Void)?
    private var watched: [AudioObjectID] = []
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }

    public init() {}

    public func processes() -> [AudioProcess] {
        AudioDevices.objects(in: Self.system, Self.list).compactMap { process in
            guard let pid: pid_t = Self.number(kAudioProcessPropertyPID, of: process) else { return nil }
            return AudioProcess(
                pid: pid,
                bundleID: AudioDevices.string(kAudioProcessPropertyBundleID, of: process) ?? "",
                isRunningInput: Self.number(kAudioProcessPropertyIsRunningInput, of: process) == UInt32(1),
                isRunningOutput: Self.number(kAudioProcessPropertyIsRunningOutput, of: process) == UInt32(1)
            )
        }
    }

    public func watch(_ onChange: @escaping @Sendable () async -> Void) {
        queue.sync {
            guard self.onChange == nil else { return }
            self.onChange = onChange
            if !listen(true, to: Self.system, Self.list) { Log.failure("audio-process-list-listener") }
            follow()
        }
    }

    public func unwatch() {
        queue.sync {
            guard onChange != nil else { return }
            onChange = nil
            listen(false, to: Self.system, Self.list)
            watched.forEach { process in Self.states.forEach { listen(false, to: process, $0) } }
            watched = []
        }
    }

    private func changed() {
        follow()
        if let onChange { Task { await onChange() } }
    }

    // A process that has gone takes its listeners with it, so a failed removal is expected.
    private func follow() {
        let current = AudioDevices.objects(in: Self.system, Self.list)
        for process in watched where !current.contains(process) {
            Self.states.forEach { listen(false, to: process, $0) }
        }
        for process in current where !watched.contains(process) {
            Self.states.forEach { listen(true, to: process, $0) }
        }
        watched = current
    }

    @discardableResult
    private func listen(_ isOn: Bool, to object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        let status = isOn
            ? AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
            : AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        return status == noErr
    }

    private static func number<Value: FixedWidthInteger>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> Value? {
        var address = AudioDevices.address(selector)
        var value: Value = 0
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
