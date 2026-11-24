import SwiftUI

// Above a sidebar's list: why the last file or recording was not taken, kept until dismissed or the next one.
struct SidebarNotice: View {
    var title: String?
    let message: String
    var isError = true
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s2) {
                if let title {
                    Text(title)
                        .font(Typeface.smallStrong)
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isError {
                    FormError(message: message)
                } else {
                    Text(message)
                        .font(Typeface.small)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.icon)
                .accessibilityLabel("Dismiss")
                .iconLabel("Dismiss")
        }
        .padding(EdgeInsets(top: Space.s4, leading: Space.s8, bottom: Space.s8, trailing: 0))
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement([title, message].compactMap(\.self).joined(separator: ": ")).post() }
    }
}
