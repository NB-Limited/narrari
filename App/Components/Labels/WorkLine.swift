import NarrariKit
import SwiftUI

// A WorkState as one line: its label, a bar while its share is known, the time it has taken when it carries a start,
// and Try again when the problem says it can help, its message then leaving out the words that say the same.
struct WorkLine: View {
    enum Bar {
        case beside(width: CGFloat)
        case below
    }

    let state: WorkState
    var symbol: String?
    var bar = Bar.below
    var track = Color.selectionFill
    var onRetry: (() -> Void)?

    var body: some View {
        if case .working(_, nil, _?) = state {
            TimelineView(.periodic(from: .now, by: MeetingMetrics.timerTick)) { context in
                line(state.label(at: context.date))
            }
        } else if let problem = state.problem, showsRetry {
            line(problem.besideRetry)
        } else {
            line(state.label)
        }
    }

    private var showsRetry: Bool { onRetry != nil && state.problem?.canRetry == true }

    @ViewBuilder private func line(_ text: String) -> some View {
        switch bar {
        case .beside(let width):
            HStack(spacing: Space.s8) {
                label(text)
                progress(text, width: width)
                retry
            }
        case .below:
            VStack(alignment: .leading, spacing: Space.s8) {
                HStack(spacing: Space.s8) {
                    label(text)
                    retry
                }
                progress(text, width: nil)
            }
        }
    }

    @ViewBuilder private func label(_ text: String) -> some View {
        let words = Text(text).monospacedDigit()
        Group {
            if let symbol {
                Label { words } icon: { Image(systemName: symbol) }.labelStyle(TightLabelStyle())
            } else {
                words
            }
        }
        .foregroundStyle(colour)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func progress(_ text: String, width: CGFloat?) -> some View {
        if let fraction = state.progress {
            ProgressBar(fraction: fraction, width: width, label: text, track: track)
        }
    }

    @ViewBuilder private var retry: some View {
        if let onRetry, showsRetry {
            Spacer(minLength: Space.s8)
            Button("Try again", action: onRetry).buttonStyle(.secondary)
        }
    }

    private var colour: Color {
        switch state {
        case .failed: .errorInk
        case .working: .ink
        case .idle, .waiting, .done: .muted
        }
    }
}
