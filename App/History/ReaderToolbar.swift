import AppKit
import NarrariKit
import SwiftUI

struct ReaderToolbar: View {
    let entry: HistoryEntry
    let library: HistoryLibrary
    let playback: AudioPlayback
    let hasAudio: Bool
    let isWorking: Bool
    let isCleaning: Bool

    @FocusState private var isConfirmFocused: Bool

    private static let noAudio = "No audio kept"
    private static let waitForCleanup = "Wait until it is cleaned up again"

    var body: some View {
        HStack(spacing: Space.s2) {
            Spacer(minLength: 0)
            if library.pendingDeletion == entry.id {
                confirmation
            } else {
                actions
            }
        }
        .padding(.horizontal, Space.s12)
        .frame(height: WindowMetrics.toolbarHeight)
    }

    @ViewBuilder private var actions: some View {
        PlayButton(playback: playback, unavailable: hasAudio ? nil : Self.noAudio)

        CopyButton(text: entry.finalText, look: .icon(label: "Copy text", shortcut: "⌘C"))

        transcribeAgain

        CleanUpAgainButton(entry: entry, library: library, isTranscribing: isWorking)

        Button { library.pendingDeletion = entry.id } label: { Image(systemName: "trash") }
            .buttonStyle(.icon)
            .disabled(!library.canDelete(entry))
            .accessibilityLabel("Delete dictation")
            .iconLabel(deleteLabel, shortcut: library.canDelete(entry) ? "⌫" : nil)
    }

    private var transcribeAgain: some View {
        AgainButton(
            names: .transcribe,
            isRunning: isWorking, unavailable: isCleaning ? Self.waitForCleanup : hasAudio ? nil : Self.noAudio,
            hint: hasAudio ? "Replaces the text with a new transcription of the audio" : Self.noAudio,
            hasLanded: { library.work[entry.id]?.state.problem == nil },
            action: { _ in Task { await library.retranscribe(entry) } }
        )
    }

    private var deleteLabel: String {
        if library.canDelete(entry) { return "Delete" }
        if isCleaning { return Self.waitForCleanup }
        return isWorking ? "Wait until it is transcribed again" : "Wait until the dictation ends"
    }

    // Asked in place, so Escape or Cancel leaves the dictation as it was.
    @ViewBuilder private var confirmation: some View {
        let question = hasAudio ? "Delete this dictation and its audio?" : "Delete this dictation?"
        Text(question)
            .font(Typeface.smallMedium)
            .foregroundStyle(Color.ink)
            .padding(.trailing, Space.s8)
        Button("Cancel") { library.pendingDeletion = nil }
            .buttonStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .padding(.trailing, Space.s4)
        Button("Delete") {
            playback.stop()
            Task { await library.delete(entry) }
        }
        .buttonStyle(.destructive)
        .keyboardShortcut(.defaultAction)
        .focused($isConfirmFocused)
        .onAppear {
            isConfirmFocused = true
            AccessibilityNotification.Announcement(question).post()
        }
    }
}
