import SwiftUI

// Asked in place, like the reader's delete: Escape or Cancel leaves everything as it was. In a list it sits in a RowBlock.
struct InlineConfirm: View {
    let message: String
    var action = "Delete"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var isConfirmFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(message)
                .font(Typeface.smallMedium)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(action) { onConfirm() }
                    .buttonStyle(.destructive)
                    .keyboardShortcut(.defaultAction)
                    .focused($isConfirmFocused)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onAppear {
            isConfirmFocused = true
            AccessibilityNotification.Announcement(message).post()
        }
        .takesEscape()
    }
}
