import Foundation

public enum MeetingsSettings {
    public static let startsByItself = Setting("meetings.startsByItself", default: false)
    public static let stopsWithCall = Setting("meetings.stopsWithCall", default: true)
    public static let usesVoiceMemory = Setting("meetings.usesVoiceMemory", default: true)
    public static let summaryTemplate = Setting("meetings.summaryTemplate", default: "general")
    public static let showsLiveText = Setting("meetings.showsLiveText", default: true)
    // A clean-up model's id, SummaryModels.outside for the chat service, or empty for the model clean-up uses on this Mac.
    public static let summaryModel = Setting("meetings.summaryModel", default: "")
    public static let bar = Setting("meetings.bar", default: MeetingBar.pill)
    public static let readsCallWindowNames = Setting("meetings.readsCallWindowNames", default: false)
    public static let ignoredApps = Setting("meetings.ignoredApps", default: [String]())
    // Names the owner said are their own, as an invite or a call's list spells them.
    public static let ownNames = Setting("meetings.ownNames", default: [String]())
    // Days a meeting keeps its audio; 0 keeps it forever. Text is never deleted by it.
    public static let audioRetentionDays = Setting("meetings.audioRetentionDays", default: 7)
    // A key code below 0 means no meeting shortcut. Modifiers are a Carbon mask, like the clean-up toggle's.
    public static let hotkeyKeyCode = Setting("meetings.hotkeyKeyCode", default: -1)
    public static let hotkeyModifiers = Setting("meetings.hotkeyModifiers", default: 0)
    // Written after each recording, because macOS gives no way to ask whether other apps' sound may be recorded.
    public static let systemAudio = Setting("meetings.systemAudio", default: Permissions.SystemAudio.notRecorded)
}
