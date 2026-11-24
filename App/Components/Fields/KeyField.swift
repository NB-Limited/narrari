import NarrariKit
import SwiftUI

// A key is never shown: the field says whether one is set, and replacing it takes a fresh paste.
struct KeyField: View {
    let label: String
    @Bindable var key: StoredKey

    var body: some View {
        FieldLabel(text: "Key")
        if key.isReplacing {
            TextInput(
                label: label, text: $key.draft, placeholder: "Paste the key", leadingSymbol: "lock.fill",
                isSecure: true, error: key.error, onSubmit: key.save
            )
            HStack(spacing: Space.s8) {
                Button("Save key", action: key.save).buttonStyle(.primary)
                Button("Cancel", action: key.cancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, Space.s8)
            .takesEscape()
        } else {
            HStack(spacing: Space.s8) {
                HStack(spacing: ControlMetrics.innerGap) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: Symbol.note))
                        .foregroundStyle(Color.muted)
                    Text(key.isSet ? "Set" : "Not set")
                        .font(Typeface.body)
                        .foregroundStyle(key.isSet ? Color.ink : Color.muted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.s8)
                .frame(height: ControlMetrics.fieldHeight)
                .fieldSurface()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(key.isSet ? "Set" : "Not set")
                Button(key.isSet ? "Replace" : "Add key", action: key.beginReplacing)
                    .buttonStyle(.secondary)
                    .accessibilityLabel(key.isSet ? "Replace \(label)" : "Add \(label)")
                if key.isSet {
                    Button("Remove", action: key.remove)
                        .buttonStyle(.destructive)
                        .accessibilityLabel("Remove \(label)")
                }
            }
            if let error = key.error {
                FormError(message: error).padding(.top, ControlMetrics.errorGap)
            }
        }
    }
}
