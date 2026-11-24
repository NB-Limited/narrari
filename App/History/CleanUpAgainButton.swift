import NarrariKit
import SwiftUI

// Opens the list of prompts; the one chosen cleans up the text as heard again, and a check says when it landed.
struct CleanUpAgainButton: View {
    let entry: HistoryEntry
    let library: HistoryLibrary
    let isTranscribing: Bool

    @State private var anchor = Anchor()
    @State private var done = TimedFlag()
    @State private var landed = CleanupChoice.asSpoken

    private static let name = "Clean up again"
    private static let nothingHeard = "Nothing heard to clean up"

    var body: some View {
        let running = library.work[entry.id].flatMap { $0.state.activity == .cleaningUp ? $0.label : nil }
        let isDone = done.isOn && running == nil
        Button(action: open) {
            Image(systemName: isDone ? "checkmark" : "text.alignleft")
        }
        .buttonStyle(.icon)
        .background(AnchorView(anchor: anchor))
        .disabled(entry.rawText.isEmpty || isTranscribing)
        .allowsHitTesting(running == nil)
        .accessibilityLabel(running ?? Self.name)
        .accessibilityHint(entry.rawText.isEmpty ? Self.nothingHeard : "Replaces the text with the heard text cleaned up by a prompt you choose")
        .iconLabel(running ?? (isDone ? landed.doneLabel : restingLabel), isPinned: running != nil || isDone)
        .onChange(of: library.work[entry.id]) { old, new in
            guard old?.state.activity == .cleaningUp, new == nil, let choice = old?.choice else { return }
            landed = choice
            done.turnOn(for: Motion.copiedHold)
            AccessibilityNotification.Announcement(choice.doneLabel).post()
        }
    }

    private var restingLabel: String {
        if entry.rawText.isEmpty { return Self.nothingHeard }
        return isTranscribing ? "Wait until it is transcribed again" : Self.name
    }

    private func open() {
        guard let view = anchor.view else { return }
        let choices = library.cleanupChoices
        Dropdown.shared.open(
            label: Self.name, rows: choices.map { DropdownRow(title: $0.title, accessory: nil) },
            chosen: choices.firstIndex { $0.made(entry) }, from: view, alignment: .trailing
        ) { index in
            run(choices[index])
        }
    }

    private func run(_ choice: CleanupChoice) {
        done.turnOff()
        Task { await library.cleanUp(entry, with: choice) }
    }
}
