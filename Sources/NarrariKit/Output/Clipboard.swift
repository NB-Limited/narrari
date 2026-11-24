import AppKit

@MainActor
public enum Clipboard {
    // Every copy the user asks for goes through here, so each one is also announced to VoiceOver.
    public static func copy(_ text: String, to pasteboard: any Pasteboard = SystemPasteboard()) {
        pasteboard.replace(with: [[PasteboardEntry(type: .string, data: Data(text.utf8))]])
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: "Copied",
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }
}
