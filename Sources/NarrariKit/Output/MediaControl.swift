import Foundation

@MainActor
public protocol OutputMuting: AnyObject {
    func muteOutput() async
    func restoreOutput() async
}

@MainActor
public protocol DeviceMuteSwitch {
    func defaultOutputUID() -> String?
    func hasMute(_ uid: String) -> Bool
    func isMuted(_ uid: String) -> Bool
    func setMuted(_ isMuted: Bool, _ uid: String) -> Bool
}

// The one fact dictation needs from a meeting: while one is under way, muting other sound would silence the call.
@MainActor
public protocol MeetingPresence: AnyObject {
    var isMeetingUnderWay: Bool { get }
}

public protocol OtherAppsSilencer: Sendable {
    func silence(outputUID: String) async -> Bool
    func restore() async
}

@MainActor
public final class MediaControl: OutputMuting {
    private let settings: SettingsStore
    private let device: any DeviceMuteSwitch
    private let otherApps: any OtherAppsSilencer
    private let meeting: (any MeetingPresence)?
    private var muteFailed = false

    public init(
        settings: SettingsStore,
        device: any DeviceMuteSwitch = OutputDeviceMute(),
        otherApps: any OtherAppsSilencer = ProcessTap(),
        meeting: (any MeetingPresence)? = nil
    ) {
        self.settings = settings
        self.device = device
        self.otherApps = otherApps
        self.meeting = meeting
    }

    public func muteOutput() async {
        guard settings.value(DictationSettings.mutesOutput) else { return }
        guard meeting?.isMeetingUnderWay != true else {
            Log.event("output-mute-skipped-for-meeting")
            return
        }
        guard let uid = device.defaultOutputUID() else {
            Log.failure("no-output-device")
            return
        }
        guard device.hasMute(uid) else {
            muteFailed = await !otherApps.silence(outputUID: uid)
            return
        }
        guard !device.isMuted(uid) else { return }

        settings.set(uid, for: DictationSettings.mutedOutputUID)
        muteFailed = !device.setMuted(true, uid)
        guard muteFailed else { return }
        settings.reset(DictationSettings.mutedOutputUID)
        Log.failure("output-mute")
    }

    // Also runs at launch, so a crash while muted never leaves the Mac silent.
    public func restoreOutput() async {
        await otherApps.restore()
        let uid = settings.value(DictationSettings.mutedOutputUID)
        guard !uid.isEmpty else { return }
        if !device.setMuted(false, uid) { Log.failure("output-unmute") }
        settings.reset(DictationSettings.mutedOutputUID)
    }

    // False after the last mute failed, until one works again.
    public func canMuteOutput() -> Bool {
        device.defaultOutputUID() != nil && !muteFailed
    }
}
