import Foundation

public enum CleanupSettings {
    public static let isEnabled = Setting("cleanup.isEnabled", default: true)
    public static let usesTriggers = Setting("cleanup.usesTriggers", default: true)
    // Codes as the language recognizer names them; a dictation detected as one of these is pasted as spoken.
    public static let skippedLanguages = Setting("cleanup.skippedLanguages", default: [String]())
    public static let engine = Setting("cleanup.engine", default: CleanupEngineKind.local)
    // Pinned to a commit, so the model never changes under the user and a model on disk loads without the network.
    public static let localModel = Setting(
        "cleanup.localModel", default: "mlx-community/Qwen3.5-2B-MLX-8bit@e6ffd0033d03c9efa880984e611028e0da63905f"
    )
    public static let chatTimeLimit = Setting("cleanup.chatTimeLimit", default: 8.0)
    // Seconds without a dictation before the in-app model is let go. It loads again at the next key press, hidden behind
    // the speaking, so a burst of dictations shares one load and a quiet Mac gets the memory back.
    public static let idleLimit = Setting("cleanup.idleLimit", default: 900.0)
    public static let chatAddress = Setting("cleanup.chatAddress", default: "")
    public static let chatModel = Setting("cleanup.chatModel", default: "")
    public static let chatKeyAccount = "cleanup.chat"
}
