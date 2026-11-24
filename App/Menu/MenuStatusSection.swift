import NarrariKit
import SwiftUI

struct MenuStatusSection: View {
    let context: MenuContext

    var body: some View {
        let status = context.model.status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MenuPanelMetrics.statusGap) {
                title(status)
                Spacer(minLength: MenuPanelMetrics.statusGap)
                trailing(status)
            }
            .font(Typeface.bodyStrong)
            .foregroundStyle(Color.ink)
            .padding(MenuPanelMetrics.statusPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(status))
            .accessibilityAddTraits(.isHeader)
            if case .loading(let work) = status, let fraction = work.progress {
                ProgressBar(fraction: fraction, width: nil, track: .panelTrack)
                    .padding(MenuPanelMetrics.progressPadding)
                    .accessibilityHidden(true)
            }
            if let fix = status.fixTitle {
                MenuRow(item: .fix, title: fix, context: context)
                    .padding(MenuPanelMetrics.fixRowPadding)
            }
        }
    }

    @ViewBuilder private func title(_ status: MenuPanelStatus) -> some View {
        switch status {
        case .problem(let title, _):
            HStack(spacing: MenuPanelMetrics.warningGap) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: MenuPanelMetrics.warningSymbol))
                Text(title)
            }
            .foregroundStyle(Color.errorInk)
        case .recording(let elapsed, _), .meeting(_, let elapsed?):
            Text(status.title)
            Text(elapsed)
                .font(Typeface.bodyMedium.monospacedDigit())
                .opacity(MenuPanelMetrics.elapsedOpacity)
        default:
            Text(status.title)
        }
    }

    @ViewBuilder private func trailing(_ status: MenuPanelStatus) -> some View {
        switch status {
        case .ready(let hotkey): HotkeyHint(verb: "hold", key: hotkey)
        case .recording(_, let hotkey): HotkeyHint(verb: "press", key: hotkey)
        case .loading:
            if let percent = status.percent {
                Text(percent)
                    .font(Typeface.labelMedium.monospacedDigit())
                    .foregroundStyle(Color.panelMuted)
            }
        default: EmptyView()
        }
    }

    private func spoken(_ status: MenuPanelStatus) -> String {
        switch status {
        case .ready(let hotkey): "Ready. Hold \(hotkey) to dictate."
        case .recording(let elapsed, let hotkey): "Recording, \(elapsed). Press \(hotkey) to stop."
        case .loading: [status.title, status.percent].compactMap(\.self).joined(separator: ", ")
        case .meeting(let title, let elapsed): [title, elapsed].compactMap(\.self).joined(separator: ", ")
        default: status.title
        }
    }
}

private struct HotkeyHint: View {
    let verb: String
    let key: String

    var body: some View {
        HStack(spacing: MenuPanelMetrics.hintGap) {
            Text(verb)
            Keycap(key: key)
        }
        .font(Typeface.labelMedium)
        .foregroundStyle(Color.panelMuted)
    }
}
