import Foundation

public enum SpeechSettings {
    public static let localModel = Setting("speech.localModel", default: ParakeetModel.recommended)
    public static let usesRemote = Setting("speech.usesRemote", default: false)
    public static let remoteAddress = Setting("speech.remoteAddress", default: "")
    public static let remoteModel = Setting("speech.remoteModel", default: "")
    // An empty code lets the service detect the language.
    public static let remoteLanguage = Setting("speech.remoteLanguage", default: "")
    public static let remoteSizeLimitBytes = Setting("speech.remoteSizeLimitBytes", default: 25_000_000)
    public static let remoteTimeLimit = Setting("speech.remoteTimeLimit", default: 10.0)
    public static let remoteKeyAccount = "speech.remote"
}
