import Foundation

public enum ModelMetric: CaseIterable, Sendable, Identifiable {
    case speed
    case accuracy
    case memory
    case disk

    public var id: Self { self }

    public func label(for job: ModelJob) -> String {
        switch self {
        case .speed: "Speed"
        case .accuracy: job == .speech ? "Accuracy" : "Quality"
        case .memory: "Memory"
        case .disk: "Disk"
        }
    }

    func value(in metrics: ModelMetrics) -> Double? {
        switch self {
        case .speed: metrics.speedSeconds
        case .accuracy: metrics.accuracy
        case .memory: metrics.memoryBytes.map(Double.init)
        case .disk: metrics.diskBytes.map(Double.init)
        }
    }

    func text(for value: Double) -> String {
        switch self {
        case .speed: MetricText.seconds(value)
        case .accuracy: MetricText.percent(value)
        case .memory, .disk: MetricText.bytes(Int64(value))
        }
    }
}

public struct MetricReading: Sendable, Equatable, Identifiable {
    public let metric: ModelMetric
    // How much of the bar is filled, 0 to 1.
    public let fraction: Double
    public let text: String

    public var id: ModelMetric { metric }

    public static let stepCount = 5

    // The meter in whole steps: the best fills all five, any measured value shows at least one.
    public var steps: Int {
        min(max(Int((fraction * Double(Self.stepCount)).rounded()), 1), Self.stepCount)
    }
}

// Bars are scaled within one list and a longer bar is always better: the best value fills it. Speed, memory and disk
// are best when smallest, so their bar is best divided by value; accuracy is value divided by best.
public enum MetricScale {
    // By model id, for lists that show their models in groups.
    public static func readings(for models: [CatalogueModel]) -> [String: [MetricReading]] {
        Dictionary(uniqueKeysWithValues: zip(models.map(\.id), readings(for: models.map(\.metrics))))
    }

    public static func readings(for list: [ModelMetrics]) -> [[MetricReading]] {
        let scales = Dictionary(uniqueKeysWithValues: ModelMetric.allCases.map { metric in
            (metric, list.compactMap { metric.value(in: $0) }.filter { $0 > 0 })
        })
        return list.map { metrics in
            ModelMetric.allCases.compactMap { metric in
                guard let value = metric.value(in: metrics), let values = scales[metric], !values.isEmpty else { return nil }
                let fraction = switch metric {
                case .speed, .memory, .disk: value > 0 ? (values.min() ?? value) / value : 0
                case .accuracy: value / (values.max() ?? value)
                }
                return MetricReading(metric: metric, fraction: min(max(fraction, 0), 1), text: metric.text(for: value))
            }
        }
    }
}

public enum MetricText {
    static let locale = Locale(identifier: "en_US")

    // "0.42 s", "1.6 s", "12 s".
    public static func seconds(_ value: Double) -> String {
        let digits = value < 1 ? 2 : value < 10 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits)).locale(locale))) s"
    }

    // "46%".
    public static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    // "483 MB", "2.7 GB": decimal units, like Finder.
    public static func bytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value < 1e9 {
            return "\(Int((value / 1e6).rounded())) MB"
        }
        return "\((value / 1e9).formatted(.number.precision(.fractionLength(1)).locale(locale))) GB"
    }
}
