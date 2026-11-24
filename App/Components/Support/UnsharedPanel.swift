import AppKit
import NarrariKit

// A borderless panel that never activates Narrari and stays out of screen sharing and recording. macOS can reset the
// sharing type when a window is shown again, so it is set on every order front.
class UnsharedPanel: NSPanel {
    private let isKeyable: Bool
    private(set) var isShown = false

    init(isKeyable: Bool) {
        self.isKeyable = isKeyable
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = .none
    }

    override var canBecomeKey: Bool { isKeyable }
    override var canBecomeMain: Bool { false }

    override func orderFront(_ sender: Any?) {
        sharingType = .none
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        sharingType = .none
        super.orderFrontRegardless()
    }

    // Fades in from where it was placed, or out and then off screen unless it was shown again meanwhile.
    func present(_ isShown: Bool, over duration: Double, reducedMotion: Bool) {
        guard isShown != self.isShown else { return }
        self.isShown = isShown
        if isShown { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? PillMotion.reduced : duration
            context.timingFunction = reducedMotion
                ? CAMediaTimingFunction(name: .linear) : (isShown ? Motion.Curve.enter : Motion.Curve.exit).timingFunction
            animator().alphaValue = isShown ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, !self.isShown else { return }
                orderOut(nil)
            }
        }
    }
}
