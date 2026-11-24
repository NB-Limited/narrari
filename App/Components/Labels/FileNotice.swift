import NarrariKit
import SwiftUI

// The top of a settings page kept in a file: the notice while the file cannot be read, then the last save's error.
struct FileNotice: View {
    let file: GuardedFile
    let storeError: String?
    let onStartFresh: () -> Void

    var body: some View {
        if file.isUnreadable {
            UnreadableFileNotice(file: file, onStartFresh: onStartFresh)
        }
        if let storeError {
            FormError(message: storeError).padding(.top, Space.s12)
        }
    }
}

// The page's editing controls are off while this shows.
private struct UnreadableFileNotice: View {
    let file: GuardedFile
    let onStartFresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormError(message: "\(file.name) could not be read.")
            Text("Narrari uses the defaults until the file is fixed or moved away. Editing is off, so nothing writes over it.")
                .font(Typeface.small)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s4)
            Text((file.url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                .font(Typeface.small)
                .foregroundStyle(Color.muted)
                .textSelection(.enabled)
                .padding(.top, Space.s4)
            HStack(spacing: Space.s8) {
                Button("Show in Finder", action: file.showInFinder)
                    .buttonStyle(.secondary)
                Button("Start fresh", action: onStartFresh)
                    .buttonStyle(.secondary)
            }
            .padding(.top, Space.s8)
            QuietLine(text: "Start fresh keeps the old file beside it, renamed to end in .unreadable and the time.")
            if let error = file.moveError {
                FormError(message: error).padding(.top, ControlMetrics.errorGap)
            }
        }
        .padding(.top, Space.s12)
    }
}
