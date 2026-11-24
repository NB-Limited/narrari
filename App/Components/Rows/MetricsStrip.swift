import NarrariKit
import SwiftUI

// Four equal columns (Speed, Accuracy or Quality, Memory, Disk), each a label and value over a five-step meter.
// A missing reading leaves its column empty, so every column sits in the same place down the list.
struct MetricsStrip: View {
    let readings: [MetricReading]
    let job: ModelJob

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SettingsGrid.metricColumnGap) {
                ForEach(ModelMetric.allCases) { cell($0) }
            }
            Grid(horizontalSpacing: SettingsGrid.metricColumnGap, verticalSpacing: SettingsGrid.metricRowGap) {
                GridRow { cell(.speed); cell(.accuracy) }
                GridRow { cell(.memory); cell(.disk) }
            }
        }
    }

    private func cell(_ metric: ModelMetric) -> some View {
        let reading = readings.first { $0.metric == metric }
        return VStack(alignment: .leading, spacing: SettingsGrid.metricBarTop) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsGrid.metricGap) {
                Text(metric.label(for: job))
                    .font(Typeface.meta)
                    .foregroundStyle(Color.muted)
                Spacer(minLength: 0)
                Text(reading?.text ?? "")
                    .font(Typeface.small.monospacedDigit())
                    .foregroundStyle(Color.ink2)
            }
            .lineLimit(1)
            .frame(height: SettingsGrid.detailLine)
            MetricMeter(steps: reading?.steps ?? 0)
        }
        .opacity(reading == nil ? 0 : 1)
        .frame(minWidth: SettingsGrid.metricCell, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.label(for: job))
        .accessibilityValue(reading?.text ?? "")
        .accessibilityHidden(reading == nil)
    }
}

// Whole steps across the column, so neighbouring rows compare at a glance and no fill ends mid-way.
private struct MetricMeter: View {
    let steps: Int

    var body: some View {
        HStack(spacing: SettingsGrid.metricStepGap) {
            ForEach(0..<MetricReading.stepCount, id: \.self) { index in
                Capsule()
                    .fill(index < steps ? Color.ink2 : Color.meterTrack)
                    .frame(height: SettingsGrid.metricStep)
            }
        }
        .accessibilityHidden(true)
    }
}
