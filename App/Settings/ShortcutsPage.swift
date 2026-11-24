import NarrariKit
import SwiftUI

struct ShortcutsPage: View {
    @Bindable var model: ShortcutsPageModel

    var body: some View {
        SettingsPage(title: "Shortcuts", subtitle: "Keys that work from any app.") {
            if let problem = model.sidedProblem {
                FormError(message: problem).padding(.top, Space.s12)
            }
            FormGroup(label: "Dictation") {
                SettingsRows {
                    RowBlock {
                        RowLine(title: "Dictation key") {
                            ShortcutRecorder(label: "Dictation key", kind: .modifierKey, field: .dictation, current: model.hotkeyName, model: model)
                        }
                        shortcutError(.dictation)
                        KeyLegend(key: model.hotkeyName)
                    }
                    SettingsRow(title: "Counts as a hold after", detail: "A shorter press is a tap.") {
                        Popup(
                            label: "Counts as a hold after",
                            selection: $model.holdThreshold,
                            options: model.holdThresholdOptions.map { ($0, "\($0.formatted()) seconds") }
                        )
                    }
                    shortcutRow(
                        "Clean-up on or off", detail: "Works while you dictate.", field: .cleanupToggle,
                        current: HotkeyName.name(of: model.cleanupToggle)
                    )
                    liveShortcutRow("Next mode", detail: "Switches the mode before you dictate.", .mode)
                    liveShortcutRow("Paste last dictation", .pasteLast)
                }
            }
            FormGroup(label: "Meetings") {
                SettingsRows {
                    liveShortcutRow("Start or stop a meeting", .meeting)
                }
            }
            FormGroup(label: "Narrari") {
                SettingsRows {
                    liveShortcutRow("Open Narrari", detail: "From any app.", .openWindow)
                    liveShortcutRow("Open Settings", .openSettings)
                }
            }
        }
    }

    private func liveShortcutRow(_ title: String, detail: String? = nil, _ live: LiveShortcut) -> some View {
        shortcutRow(
            title, detail: detail, field: .live(live), current: model.liveShortcuts[live].map(HotkeyName.name(of:)),
            onClear: { model.clear(live) }
        )
    }

    private func shortcutRow(
        _ title: String, detail: String? = nil, field: ShortcutsPageModel.ShortcutField, current: String?, onClear: (() -> Void)? = nil
    ) -> some View {
        RowBlock {
            RowLine(title: title, detail: detail) {
                if let onClear, current != nil {
                    Button("Clear", action: onClear)
                        .buttonStyle(.secondary)
                        .accessibilityLabel("Clear \(title)")
                }
                ShortcutRecorder(label: title, kind: .combination, field: field, current: current, model: model)
            }
            shortcutError(field)
        }
    }

    @ViewBuilder private func shortcutError(_ field: ShortcutsPageModel.ShortcutField) -> some View {
        if let error = model.shortcutErrors[field] ?? (model.isNotWorking(field) ? "Not working. See the note at the top." : nil) {
            FormError(message: error).padding(.top, ControlMetrics.errorGap)
        }
    }
}

// The two ways the dictation key works, drawn with the real key.
private struct KeyLegend: View {
    let key: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: SettingsGrid.legendColumnGap, verticalSpacing: SettingsGrid.legendRowGap) {
            GridRow {
                word("Hold")
                HStack(spacing: SettingsGrid.legendGap) {
                    Keycap(key: key)
                    Capsule()
                        .fill(Color.ink)
                        .frame(width: SettingsGrid.heldBar.width, height: SettingsGrid.heldBar.height)
                }
                .frame(minWidth: SettingsGrid.legendSequence, alignment: .leading)
                outcome("Talk, then let go to paste.")
            }
            GridRow {
                word("Tap")
                HStack(spacing: SettingsGrid.legendGap) {
                    Keycap(key: key)
                    HStack(spacing: SettingsGrid.tapDotGap) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Color.muted).frame(width: SettingsGrid.tapDot, height: SettingsGrid.tapDot)
                        }
                    }
                    Keycap(key: key)
                }
                .frame(minWidth: SettingsGrid.legendSequence, alignment: .leading)
                outcome("Tap to start, again to paste.")
            }
        }
        .padding(.top, SettingsGrid.legendTop)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold \(key) to talk, then let go to paste. Or tap \(key) to start and tap again to paste.")
    }

    private func word(_ text: String) -> some View {
        Text(text)
            .font(Typeface.smallStrong)
            .foregroundStyle(Color.ink)
            .frame(width: SettingsGrid.legendWord, alignment: .leading)
    }

    private func outcome(_ text: String) -> some View {
        Text(text)
            .font(Typeface.small)
            .foregroundStyle(Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
