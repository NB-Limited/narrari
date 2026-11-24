import AppKit
import NarrariKit
import SwiftUI

// A borderless child panel for the dropdown list and the hover label. Being its own window, nothing in the
// window clips it; being a child, it moves with the window. Keys are read here, before any view.
final class FloatingPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    private let isKeyable: Bool

    init(isKeyable: Bool) {
        self.isKeyable = isKeyable
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = !isKeyable
    }

    override var canBecomeKey: Bool { isKeyable }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey {
            onKey(event)
            return
        }
        super.sendEvent(event)
    }

    // Shows the SwiftUI content next to the anchor, over its window, kept on the anchor's screen.
    // A leading reach starts it that much left of the anchor, so a list's titles line up with the control's.
    func show(
        _ content: some View, size: CGSize, anchor: NSView, gap: CGFloat, alignment: AnchoredPlacement.Alignment, leadingReach: CGFloat = 0
    ) {
        guard let parent = anchor.window, let screen = parent.screen ?? NSScreen.main else { return }
        var anchorFrame = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        anchorFrame.origin.x -= leadingReach
        anchorFrame.size.width += leadingReach
        let frame = AnchoredPlacement.frame(size: size, anchor: anchorFrame, gap: gap, alignment: alignment, within: screen.visibleFrame)
        appearance = parent.effectiveAppearance
        let hosting = NSHostingView(rootView: content.frame(width: frame.width, height: frame.height))
        hosting.sizingOptions = []
        contentView = hosting
        setFrame(frame, display: true)
        sharingType = parent.sharingType
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
        invalidateShadow()
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
    }
}

// The AppKit view behind a SwiftUI control, so a floating panel can find where the control is on screen.
@MainActor
final class Anchor {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let anchor: Anchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
