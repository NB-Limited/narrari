import AppKit
import NarrariKit
import SwiftUI

// A list row's right-click and Control-click, which open its menu without selecting it; its view is where the menu opens from.
struct RowMenuArea: NSViewRepresentable {
    let anchor: Anchor
    let onMenu: () -> Void

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SecondaryClickView, context: Context) {
        anchor.view = view
        view.onMenu = onMenu
    }
}

// Takes only a secondary click, so every other click, the hover and the scroll reach the row under it.
final class SecondaryClickView: NSView {
    var onMenu: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.isSecondary(event) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?()
    }

    override func mouseDown(with event: NSEvent) {
        onMenu?()
    }

    private static func isSecondary(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
}

// The anchor of each row shown, so ⌃Return opens the selected row's menu from the row itself.
@MainActor
final class RowAnchors<ID: Hashable> {
    private var anchors: [ID: Anchor] = [:]

    func anchor(_ id: ID) -> Anchor {
        if let anchor = anchors[id] { return anchor }
        let anchor = Anchor()
        anchors[id] = anchor
        return anchor
    }

    func view(_ id: ID?) -> NSView? {
        id.flatMap { anchors[$0]?.view }
    }
}

extension Dropdown {
    // A row's menu under the row, ending on its right edge; a copy goes to the clipboard here, anything else to the list.
    func open(_ rows: [RowMenu.Row], label: String, from view: NSView, perform: @escaping (RowMenu.Action) -> Void) {
        let shown = rows.map { DropdownRow(title: $0.title, startsSection: $0.startsSection) }
        open(label: label, rows: shown, chosen: nil, from: view, alignment: .trailing) { index in
            switch rows[index].action {
            case .copy(let text): Clipboard.copy(text)
            case let action: perform(action)
            }
        }
    }
}
