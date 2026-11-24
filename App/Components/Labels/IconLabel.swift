import AppKit
import NarrariKit
import SwiftUI

extension View {
    // Names an icon-only button: a small label under it after a short hover or on keyboard focus.
    // Pinned shows it at once, for a result such as "Copied". A pill surface tracks the pointer while another app is in front.
    func iconLabel(_ text: String, shortcut: String? = nil, isPinned: Bool = false, tracksPointerAlways: Bool = false) -> some View {
        modifier(IconLabelModifier(text: text, shortcut: shortcut, isPinned: isPinned, tracksPointerAlways: tracksPointerAlways))
    }
}

private struct IconLabelModifier: ViewModifier {
    let text: String
    let shortcut: String?
    let isPinned: Bool
    let tracksPointerAlways: Bool

    @State private var reveal = TimedFlag()
    @State private var anchor = Anchor()
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        let shown = isPinned || reveal.isOn
        content
            .focused($isFocused)
            .onHover { if !tracksPointerAlways { isHovered = $0 } }
            .background { if tracksPointerAlways { PointerArea { isHovered = $0 } } }
            .background(AnchorView(anchor: anchor))
            .onChange(of: isHovered || isFocused) { _, wanted in
                wanted ? reveal.turnOn(after: Motion.labelDelay) : reveal.turnOff()
            }
            .onChange(of: LabelContent(text: text, shortcut: shortcut, isShown: shown), initial: true) { _, label in
                if label.isShown { HoverLabel.shared.show(label, under: anchor) } else { HoverLabel.shared.hide(for: anchor) }
            }
            .onDisappear {
                reveal.turnOff()
                HoverLabel.shared.hide(for: anchor)
            }
    }
}

struct LabelContent: Equatable {
    let text: String
    let shortcut: String?
    var isShown = true
}

// One label on screen at a time, under the button it names, only in the window that has the keyboard or in a pill surface,
// which never takes it.
@MainActor
final class HoverLabel {
    static let shared = HoverLabel()

    private let panel = FloatingPanel(isKeyable: false)
    private weak var owner: Anchor?
    private var resignObserver: (any NSObjectProtocol)?

    private init() {
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, let owner = self.owner, let parent = owner.view?.window, window == ObjectIdentifier(parent) else { return }
                self.hide(for: owner)
            }
        }
    }

    isolated deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func show(_ label: LabelContent, under anchor: Anchor) {
        guard let view = anchor.view, let window = view.window, window.isKeyWindow || !window.canBecomeKey else { return }
        owner = anchor
        let bubble = LabelBubble(label: label)
        let size = NSHostingView(rootView: bubble).fittingSize
        panel.show(bubble, size: size, anchor: view, gap: FloatingMetrics.gap, alignment: .center)
    }

    func hide(for anchor: Anchor) {
        guard owner === anchor else { return }
        owner = nil
        panel.hide()
    }
}

struct LabelBubble: View {
    let label: LabelContent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FloatingMetrics.labelRadius)
        HStack(spacing: FloatingMetrics.labelShortcutGap) {
            Text(label.text).foregroundStyle(Color.ink)
            if let shortcut = label.shortcut {
                Text(shortcut).foregroundStyle(Color.muted)
            }
        }
        .font(Typeface.small)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, FloatingMetrics.labelPadding)
        .frame(height: FloatingMetrics.labelHeight)
        .background(Color.surface, in: shape)
        .overlay(shape.strokeBorder(Color.rule, lineWidth: FloatingMetrics.edge))
        .accessibilityHidden(true)
    }
}
