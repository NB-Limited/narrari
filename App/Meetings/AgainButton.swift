import AppKit
import NarrariKit
import SwiftUI

// Transcribe again, Find speakers again and Redo summary, built like the reader's Transcribe again: the arrow turns while
// the step runs again, and a check says when it landed.
struct AgainButton: View {
    let page: MeetingPage
    let step: MeetingProcessing.Step
    // Why it cannot run now, said in its label.
    let unavailable: String?
    let action: (_ from: NSView?) -> Void

    @State private var anchor = Anchor()
    @State private var landed = TimedFlag()
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let isRunning = page.redoing == step
        let names = Self.names(step)
        Button { action(anchor.view) } label: {
            Image(systemName: landed.isOn && !isRunning ? "checkmark" : "arrow.clockwise")
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRunning && !reduceMotion)
        }
        .buttonStyle(.icon)
        .background(AnchorView(anchor: anchor))
        .disabled(unavailable != nil && !isRunning)
        .allowsHitTesting(!isRunning)
        .accessibilityLabel(isRunning ? names.running : names.title)
        .iconLabel(isRunning ? names.running : landed.isOn ? names.done : unavailable ?? names.resting, isPinned: isRunning || landed.isOn)
        .onChange(of: isRunning) { _, running in
            guard !running, page.meeting.steps[step].status == .done else { return }
            landed.turnOn(for: Motion.copiedHold)
            AccessibilityNotification.Announcement(names.done).post()
        }
    }

    private static func names(_ step: MeetingProcessing.Step) -> (title: String, resting: String, running: String, done: String) {
        switch step {
        case .transcript: ("Transcribe again", "Transcribe again from the audio", "Transcribing again", "Transcribed again")
        case .speakers: ("Find speakers again", "Find speakers again", "Finding speakers again", "Speakers found again")
        case .summary, .echo: ("Redo summary", "Redo summary", "Redoing the summary", "Summary redone")
        }
    }
}
