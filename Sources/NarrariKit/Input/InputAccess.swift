import AppKit
import ApplicationServices
import Carbon.HIToolbox

public struct InputAccess: Sendable {
    public var isAccessibilityGranted: @Sendable () -> Bool
    public var modifiersHeld: @Sendable () -> Bool

    public init(isAccessibilityGranted: @escaping @Sendable () -> Bool, modifiersHeld: @escaping @Sendable () -> Bool = { false }) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.modifiersHeld = modifiersHeld
    }

    public static let system = InputAccess(
        isAccessibilityGranted: { AXIsProcessTrusted() },
        modifiersHeld: {
            !CGEventSource.flagsState(.hidSystemState).isDisjoint(with: [.maskControl, .maskAlternate, .maskShift, .maskCommand])
        }
    )

    private static let accessibilityPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    // The prompt adds Narrari to the Accessibility list; it shows only once per app, so the pane opens as well.
    @MainActor public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(accessibilityPane)
    }
}
