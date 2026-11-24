import AppKit
import NarrariKit
import SwiftUI

struct EmptyMeetingsPage: View {
    let retentionDays: Int
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        let audio = retentionDays > 0 ? "the audio for \(HistoryPageModel.title(forDays: retentionDays))" : "the audio too"
        PagePrompt(
            said: "Join a call and choose Start.",
            heard: "Narrari offers to record when another app uses the microphone. The text is kept until you delete it, \(audio)."
        ) {
            HStack(spacing: Space.s8) {
                Button("Record a meeting", action: onRecord).buttonStyle(.primary)
                Button("Import a recording", action: onImport).buttonStyle(.secondary)
            }
        }
    }
}

struct ImportingMeetingPage: View {
    var body: some View {
        PagePrompt(said: "Importing the recording.", heard: "Its transcript and summary are made once it is read in.")
    }
}

struct NoMeetingResultsPage: View {
    let query: String

    var body: some View {
        PagePrompt(
            said: "Nothing matches “\(query)”.",
            heard: "Search looks through titles, people, notes, summaries and transcripts."
        )
    }
}

// A folder whose meeting.json can't be read: what happened, that nothing was touched, and where it is.
struct UnreadableMeetingPage: View {
    let folder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormError(message: "meeting.json could not be read.")
            Text("The recording and text files in its folder are untouched. Narrari never deletes this folder.")
                .font(Typeface.small)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, ControlMetrics.errorGap)
            Text((folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                .font(Typeface.small)
                .foregroundStyle(Color.muted)
                .textSelection(.enabled)
                .padding(.top, Space.s4)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                .buttonStyle(.secondary)
                .padding(.top, Space.s12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: WindowMetrics.toolbarHeight + ControlMetrics.innerGap, leading: Space.s36, bottom: Space.s36, trailing: Space.s36))
    }
}
