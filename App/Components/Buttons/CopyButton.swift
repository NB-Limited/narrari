import NarrariKit
import SwiftUI

// Every copy button in the window: copies, then says "Copied" for a moment, so a copy is never silent.
struct CopyButton: View {
    enum Look {
        case icon(label: String, shortcut: String?)
        case primary
    }

    let text: String
    var look = Look.icon(label: "Copy text", shortcut: nil)

    @State private var copied = TimedFlag()

    var body: some View {
        switch look {
        case .icon(let label, let shortcut):
            Button(action: copy) { Image(systemName: copied.isOn ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.icon)
                .disabled(text.isEmpty)
                .accessibilityLabel(label)
                .iconLabel(text.isEmpty ? "No text to copy" : copied.isOn ? "Copied" : label, shortcut: copied.isOn ? nil : shortcut, isPinned: copied.isOn)
        case .primary:
            Button(copied.isOn ? "Copied" : "Copy", action: copy)
                .buttonStyle(.primary)
                .disabled(text.isEmpty)
        }
    }

    private func copy() {
        Clipboard.copy(text)
        copied.turnOn(for: Motion.copiedHold)
    }
}
