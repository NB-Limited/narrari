import AppKit
import ApplicationServices

// A call app's windows through the Accessibility interface Narrari holds for pasting; nothing here asks for it.
public actor AccessibilityCallWindows: CallWindowSource {
    private static let depth = 40
    private static let limit = 5_000
    private static let timeout: Float = 0.5
    // Electron and Chromium apps build their tree for a client that sets this; AXEnhancedUserInterface would too, but slows window moves.
    private static let assistiveMode = "AXManualAccessibility"

    public init() {}

    public func windows(of app: String) -> [WindowElement] {
        guard let element = Self.element(of: app) else { return [] }
        var budget = Self.limit
        return Self.elements(element, kAXWindowsAttribute).map { Self.read($0, depth: Self.depth, budget: &budget) }
    }

    public func assistiveMode(of app: String) -> Bool {
        guard let element = Self.element(of: app) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, Self.assistiveMode as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }

    public func setAssistiveMode(_ isOn: Bool, of app: String) {
        guard let element = Self.element(of: app) else { return }
        if AXUIElementSetAttributeValue(element, Self.assistiveMode as CFString, (isOn ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) != .success {
            Log.failure("call-window-assistive-mode")
        }
    }

    private static func element(of app: String) -> AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    // A busy app answers nothing until the timeout, so one unanswered element ends the read.
    private static func read(_ element: AXUIElement, depth: Int, budget: inout Int) -> WindowElement {
        guard budget > 0 else { return WindowElement(role: "") }
        budget -= 1
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .cannotComplete { budget = 0 }
        let children = depth > 0 && budget > 0 ? elements(element, kAXChildrenAttribute) : []
        return WindowElement(
            role: role as? String ?? "", title: string(element, kAXTitleAttribute), value: string(element, kAXValueAttribute),
            label: string(element, kAXDescriptionAttribute),
            children: children.map { read($0, depth: depth - 1, budget: &budget) }
        )
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
