import AppKit
import NarrariKit
import SwiftUI

// Listens for the next key while recording. Keys from this window are swallowed, so Escape cancels the recording
// instead of leaving Settings; leaving the window, the app or the page ends it too.
struct ShortcutRecorder: View {
    enum Kind {
        case modifierKey
        case combination
    }

    let label: String
    let kind: Kind
    let field: ShortcutsPageModel.ShortcutField
    // Nil when no shortcut is set.
    let current: String?
    let model: ShortcutsPageModel

    @State private var monitor: Any?

    private var isRecording: Bool { model.recording == field }

    var body: some View {
        Button {
            isRecording ? model.endRecording() : model.beginRecording(field)
        } label: {
            RecorderLabel(
                text: isRecording ? prompt : current ?? "None", isRecording: isRecording, isEmpty: current == nil,
                isError: model.shortcutErrors[field] != nil || model.isNotWorking(field)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isRecording ? "Recording" : current ?? "None")
        .accessibilityHint(isRecording ? prompt : "Press to record a new shortcut")
        .onChange(of: isRecording) { _, recording in recording ? startListening() : stopListening() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording { model.endRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if isRecording { model.endRecording() }
        }
        .onDisappear {
            stopListening()
            model.endRecording()
        }
    }

    private var prompt: String {
        switch kind {
        case .modifierKey: "Press a modifier key"
        case .combination: "Press the shortcut"
        }
    }

    private func startListening() {
        stopListening()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        switch (kind, event.type) {
        case (.modifierKey, .flagsChanged):
            guard !modifiers.isEmpty else { return true }
            model.record(modifierKey: Int(event.keyCode))
        case (.modifierKey, .keyDown):
            if Shortcut(keyCode: event.keyCode, flags: []).isEscape, modifiers.isEmpty { model.endRecording() } else { model.refuseKeyForDictation() }
        case (.combination, .keyDown):
            let shortcut = Shortcut(keyCode: event.keyCode, flags: event.modifierFlags)
            if shortcut.isEscape, !shortcut.hasCommandOptionOrControl { model.endRecording() } else { model.record(shortcut, for: field) }
        default:
            break
        }
        return true
    }
}

private struct RecorderLabel: View {
    let text: String
    let isRecording: Bool
    let isEmpty: Bool
    let isError: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(text)
            .font(Typeface.body)
            .foregroundStyle(isRecording || isEmpty ? Color.muted : Color.ink)
            .lineLimit(1)
            .padding(.horizontal, Space.s8)
            .frame(width: SettingsGrid.controlWidth, alignment: .leading)
            .frame(height: ControlMetrics.fieldHeight)
            .fieldSurface(isError: isError, fill: isRecording ? .selectionFill : .surface)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .focusRing(isFocused)
    }
}
