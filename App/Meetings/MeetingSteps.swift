import NarrariKit
import SwiftUI

// The work after a meeting, one row a step; the step at work reads in Ink with its verb and the time it has taken.
struct MeetingSteps: View {
    let rows: [MeetingPage.StepRow]
    let page: MeetingPage

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.s8, verticalSpacing: 0) {
            ForEach(rows) { row in
                GridRow {
                    symbol(row.work)
                        .frame(width: MeetingWindowMetrics.stepSymbol)
                    Text(row.name)
                        .foregroundStyle(Color.ink2)
                        .frame(width: MeetingWindowMetrics.stepName, alignment: .leading)
                    status(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // A step waiting for a model that is not downloading waits until asked again.
                    if case .waiting = row.work, row.action == .download {
                        Button("Try again") { tryAgain(row) }
                            .buttonStyle(.secondary)
                    }
                }
                .frame(minHeight: MeetingWindowMetrics.stepRow)
                .accessibilityElement(children: .combine)
            }
        }
        .font(Typeface.small)
    }

    @ViewBuilder private func symbol(_ work: WorkState) -> some View {
        switch work {
        case .done, .idle: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ink2)
        case .working: LoadingRadio(colour: .ink, size: Symbol.window, lineWidth: ControlMetrics.focusRing)
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(Color.muted)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.errorInk)
        }
    }

    @ViewBuilder private func status(_ row: MeetingPage.StepRow) -> some View {
        if let note = row.note {
            Text(note).foregroundStyle(Color.muted)
        } else {
            let retry = row.action == nil ? nil : { tryAgain(row) }
            WorkLine(state: row.work, bar: .beside(width: MeetingWindowMetrics.stepBar.width), track: .meterTrack, onRetry: retry)
        }
    }

    private func tryAgain(_ row: MeetingPage.StepRow) {
        Task { await page.tryAgain(row) }
    }
}

// In place of a tab's content while it has none: what it waits for, or why there is none.
struct EmptyTabLine: View {
    let text: String

    var body: some View {
        Text(text).font(Typeface.small).foregroundStyle(Color.muted)
    }
}
