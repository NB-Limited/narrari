import NarrariKit
import SwiftUI

// The work after a meeting, one row a step; the step at work reads in Ink with its verb and the time it has taken.
struct MeetingSteps: View {
    let rows: [MeetingPage.StepRow]
    let page: MeetingPage

    var body: some View {
        TimelineView(.periodic(from: .now, by: MeetingMetrics.timerTick)) { context in
            Grid(alignment: .leading, horizontalSpacing: Space.s8, verticalSpacing: 0) {
                ForEach(rows) { row in
                    GridRow {
                        symbol(row.look)
                            .frame(width: MeetingWindowMetrics.stepSymbol)
                        Text(row.name)
                            .foregroundStyle(Color.ink2)
                            .frame(width: MeetingWindowMetrics.stepName, alignment: .leading)
                        status(row, now: context.date)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if row.action != nil {
                            Button("Try again") { Task { await page.tryAgain(row) } }
                                .buttonStyle(.secondary)
                        }
                    }
                    .frame(minHeight: MeetingWindowMetrics.stepRow)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .font(Typeface.small)
    }

    @ViewBuilder private func symbol(_ look: MeetingPage.StepRow.Look) -> some View {
        switch look {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ink2)
        case .working: LoadingRadio(colour: .ink, size: Symbol.window, lineWidth: ControlMetrics.focusRing)
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(Color.muted)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.errorInk)
        }
    }

    private func status(_ row: MeetingPage.StepRow, now: Date) -> some View {
        HStack(spacing: Space.s8) {
            Text(row.text(at: now))
                .foregroundStyle(row.look == .failed ? Color.errorInk : row.look == .working ? Color.ink : Color.muted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let progress = row.progress {
                ProgressBar(fraction: progress, width: MeetingWindowMetrics.stepBar.width, label: row.name, track: .meterTrack)
            }
        }
    }
}

// In place of a tab's content while it has none: what it waits for, or why there is none.
struct EmptyTabLine: View {
    let text: String

    var body: some View {
        Text(text).font(Typeface.small).foregroundStyle(Color.muted)
    }
}
