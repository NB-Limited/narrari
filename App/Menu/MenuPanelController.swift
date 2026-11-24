import AppKit
import Carbon.HIToolbox
import NarrariKit
import SwiftUI

// The N in the menu bar and the panel under it: placing, opening and closing it, and its keyboard.
// The panel's view exists only while it is open, so nothing behind it runs while it is closed.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    private enum Phase {
        case closed
        case open
        case closing
    }

    private let model: MenuPanel
    private let permissions: Permissions
    private let surfaces: MeetingSurfaces
    private let motion: ReduceMotion
    private let perform: (MenuPanelAction) -> Void
    private let press = MenuPress()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let window = MenuPanelWindow()
    private var phase = Phase.closed
    private var top: CGFloat = 0
    private var monitors: [Any] = []
    private var pending: Task<Void, Never>?

    init(
        model: MenuPanel, permissions: Permissions, surfaces: MeetingSurfaces, motion: ReduceMotion,
        perform: @escaping (MenuPanelAction) -> Void
    ) {
        self.model = model
        self.permissions = permissions
        self.surfaces = surfaces
        self.motion = motion
        self.perform = perform
        super.init()
        window.delegate = self
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        showIcon()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    @objc private func toggle() {
        phase == .closed ? open() : close()
    }

    // While the screen is watched during a meeting, the plain N: the dot would say a meeting records.
    private func showIcon() {
        let (isAllowed, marksRecording) = withObservationTracking {
            (permissions.isAccessibilityAllowed, surfaces.marksRecording)
        } onChange: { [weak self] in
            Task { @MainActor in self?.showIcon() }
        }
        guard let button = statusItem.button else { return }
        button.window?.sharingType = .none
        if isAllowed {
            button.image = marksRecording ? Self.recordingIcon : NSImage(named: "MenuBarIcon")
            button.setAccessibilityLabel(marksRecording ? "Narrari, recording a meeting" : "Narrari")
        } else {
            let label = "Narrari: Accessibility not allowed"
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: label)
            button.image?.isTemplate = true
            button.setAccessibilityLabel(label)
        }
    }

    // The N with a 4 pt dot at its lower right, still a template so macOS tints it.
    private static let recordingIcon: NSImage? = {
        guard let mark = NSImage(named: "MenuBarIcon") else { return nil }
        let image = NSImage(size: mark.size, flipped: false) { rect in
            mark.draw(in: rect)
            let dot = MenuPanelMetrics.recordingDot
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot, y: rect.minY, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private func open() {
        guard phase == .closed, let anchor = statusItem.button?.window else { return }
        phase = .open
        model.open()
        let context = MenuContext(model: model, press: press) { [weak self] item in self?.activate(item) }
        let hosting = NSHostingView(rootView: panelView(context, isGlass: false))
        let background = MenuPanelBackground.wrap(hosting)
        hosting.rootView = panelView(context, isGlass: background.isGlass)
        window.contentView = background.view

        let size = hosting.fittingSize
        let screen = anchor.screen?.frame ?? anchor.frame
        let left = min(anchor.frame.minX - MenuPanelMetrics.leadingOffset, screen.maxX - size.width - MenuPanelMetrics.screenMargin)
        top = anchor.frame.minY - MenuPanelMetrics.belowMenuBar
        let frame = NSRect(x: left, y: top - size.height, width: size.width, height: size.height)
        let isMoving = !motion.isOn
        window.setFrame(isMoving ? frame.offsetBy(dx: 0, dy: MenuPanelMetrics.openRise) : frame, display: false)
        window.alphaValue = isMoving ? 0 : 1
        window.orderFrontRegardless()
        window.makeKey()
        statusItem.button?.highlight(true)
        watchClicksOutside()
        guard isMoving else { return }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = MenuPanelMetrics.openDuration
            animation.timingFunction = Motion.Curve.enter.timingFunction
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func panelView(_ context: MenuContext, isGlass: Bool) -> some View {
        MenuPanelView(context: context, isGlass: isGlass) { [weak self] size in self?.resize(to: size) }.followsMotion(motion)
    }

    // Rows come and go while it is open (the mode list, a status line), so it grows and shrinks from the top.
    private func resize(to size: CGSize) {
        guard phase == .open, size.height > 0 else { return }
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func close(then action: MenuPanelAction? = nil) {
        guard phase == .open else { return }
        phase = .closing
        pending?.cancel()
        pending = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        statusItem.button?.highlight(false)
        guard !motion.isOn else { return finishClosing(then: action) }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = MenuPanelMetrics.closeDuration
            animation.timingFunction = Motion.Curve.exit.timingFunction
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishClosing(then: action) }
        }
    }

    private func finishClosing(then action: MenuPanelAction?) {
        window.orderOut(nil)
        window.contentView = nil
        model.close()
        press.item = nil
        phase = .closed
        if let action { perform(action) }
    }

    // A click anywhere else closes it, as a menu does; the status item's own click toggles instead.
    private func watchClicksOutside() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            guard let self, event.window !== window, event.window !== statusItem.button?.window else { return event }
            close()
            return event
        }) {
            monitors.append(local)
        }
    }

    private func activate(_ item: MenuPanelItem) {
        switch model.activate(item) {
        case .stayOpen: break
        case .close(let action): close(then: action)
        case .closeShowingCopied: closeAfterCopy()
        }
    }

    private func closeAfterCopy() {
        pending = Task { [weak self] in
            try? await Task.sleep(for: MenuPanelMetrics.copiedHold)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func pressHighlighted() {
        guard pending == nil, let item = model.highlighted else { return }
        press.item = item
        pending = Task { [weak self] in
            try? await Task.sleep(for: MenuPanelMetrics.keyPress)
            guard let self, !Task.isCancelled else { return }
            press.item = nil
            pending = nil
            activate(item)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "c": activate(.lastDictation)
            case ",": activate(.settings)
            case "q": activate(.quit)
            default: return false
            }
            return true
        }
        switch Int(event.keyCode) {
        case kVK_DownArrow: model.moveHighlight(by: 1)
        case kVK_UpArrow: model.moveHighlight(by: -1)
        case kVK_Tab: model.moveHighlight(by: modifiers.contains(.shift) ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: pressHighlighted()
        case kVK_Escape: close()
        default: return false
        }
        return true
    }
}
