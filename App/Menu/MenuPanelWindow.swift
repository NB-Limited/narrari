import AppKit

// Takes the keyboard without activating Narrari, so the app in front stays in front.
final class MenuPanelWindow: UnsharedPanel {
    var onKey: ((NSEvent) -> Bool)?

    init() {
        super.init(isKeyable: true)
        level = .popUpMenu
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    // Keys are read here, before any view, so the panel's keyboard never depends on SwiftUI focus.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
enum MenuPanelBackground {
    // Liquid Glass from macOS 26; before it, the menu material with the panel's corners masked.
    static func wrap(_ content: NSView) -> (view: NSView, isGlass: Bool) {
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = MenuPanelMetrics.radius
            glass.contentView = content
            return (glass, true)
        }
        let material = NSVisualEffectView()
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = cornerMask(radius: MenuPanelMetrics.radius)
        content.frame = material.bounds
        material.addSubview(content)
        return (material, false)
    }

    static func cornerMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
