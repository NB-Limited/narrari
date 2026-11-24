import Foundation

// A muting tap silences nothing until it is read, so its reader runs and drops what it reads.
public actor ProcessTap: OtherAppsSilencer {
    private var tap: SystemAudioTap?

    public init() {}

    public func silence(outputUID: String) -> Bool {
        guard tap == nil else { return true }
        let began = ProcessInfo.processInfo.systemUptime
        guard let tap = SystemAudioTap(.mute, outputUID: outputUID), tap.start(reading: { _, _, _, _, _ in }) else { return false }
        self.tap = tap
        Log.timing("output-muted-by-tap", seconds: ProcessInfo.processInfo.systemUptime - began)
        return true
    }

    public func restore() {
        guard let tap else { return }
        let began = ProcessInfo.processInfo.systemUptime
        self.tap = nil
        if tap.remove() { Log.timing("output-tap-removed", seconds: ProcessInfo.processInfo.systemUptime - began) }
    }
}
