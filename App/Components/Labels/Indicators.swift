import NarrariKit
import SwiftUI

struct ProgressBar: View {
    let fraction: Double
    var width: CGFloat?
    var label = "Progress"
    var track = Color.selectionFill

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(track)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: Radius.bar)
                        .fill(Color.ink)
                        .frame(width: geometry.size.width * clamped)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.bar))
            .frame(width: width, height: ControlMetrics.progressHeight)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(MetricText.percent(clamped))
    }
}

struct LeavesMacTag: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "network")
            .labelStyle(TightLabelStyle())
            .font(Typeface.smallStrong)
            .foregroundStyle(Color.ink)
    }
}

// A quiet word in a hairline box beside a name, such as "Recommended" or "Default".
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.labelMedium)
            .foregroundStyle(Color.muted)
            .lineLimit(1)
            .padding(.horizontal, SettingsGrid.tagPadding)
            .frame(height: SettingsGrid.tagHeight)
            .overlay(RoundedRectangle(cornerRadius: SettingsGrid.tagRadius).strokeBorder(Color.tagEdge, lineWidth: ControlMetrics.edge))
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: ControlMetrics.innerGap) {
            configuration.icon
            configuration.title
        }
    }
}
