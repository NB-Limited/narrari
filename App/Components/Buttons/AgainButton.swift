import AppKit
import NarrariKit
import SwiftUI

// Transcribe again, Find speakers again and Redo summary: the arrow turns while the work runs again, and a check says when it landed.
struct AgainButton: View {
    struct Names {
        let title: String
        let resting: String
        let running: WorkState.Activity
        let done: String

        static let transcribe = Names(title: "Transcribe again", resting: "Transcribe again from the audio", running: .transcribing, done: "Transcribed again")
    }

    let names: Names
    let isRunning: Bool
    // Why it cannot run now, said in its label.
    let unavailable: String?
    var hint: String?
    // Asked once a run ends: whether its result is in.
    let hasLanded: () -> Bool
    let action: (_ from: NSView?) -> Void

    @State private var anchor = Anchor()
    @State private var landed = TimedFlag()
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let running = names.running.label
        Button { action(anchor.view) } label: {
            Image(systemName: landed.isOn && !isRunning ? "checkmark" : "arrow.clockwise")
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRunning && !reduceMotion)
        }
        .buttonStyle(.icon)
        .background(AnchorView(anchor: anchor))
        .disabled(unavailable != nil && !isRunning)
        .allowsHitTesting(!isRunning)
        .accessibilityLabel(isRunning ? running : names.title)
        .accessibilityHint(hint ?? "")
        .iconLabel(isRunning ? running : landed.isOn ? names.done : unavailable ?? names.resting, isPinned: isRunning || landed.isOn)
        .onChange(of: isRunning) { _, isRunning in
            guard !isRunning, hasLanded() else { return }
            landed.turnOn(for: Motion.copiedHold)
            AccessibilityNotification.Announcement(names.done).post()
        }
    }
}
