import NarrariKit
import Testing

struct ModelMetricReadingsTests {
    @Test func the_best_value_fills_the_bar_for_every_metric() throws {
        let fast = ModelMetrics(speedSeconds: 0.4, accuracy: 0.9, memoryBytes: 500_000_000, diskBytes: 2_000_000_000)
        let slow = ModelMetrics(speedSeconds: 1.6, accuracy: 0.99, memoryBytes: 2_000_000_000, diskBytes: 500_000_000)

        let readings = MetricScale.readings(for: [fast, slow])

        let fraction = { (row: Int, metric: ModelMetric) in readings[row].first { $0.metric == metric }?.fraction }
        #expect(fraction(0, .speed) == 1)
        #expect(fraction(1, .speed) == 0.25)
        #expect(fraction(1, .accuracy) == 1)
        #expect(try #require(fraction(0, .accuracy)) == 0.9 / 0.99)
        #expect(fraction(0, .memory) == 1)
        #expect(fraction(1, .memory) == 0.25)
        #expect(fraction(1, .disk) == 1)
        #expect(fraction(0, .disk) == 0.25)
        #expect(readings[1].first { $0.metric == .memory }?.text == "2.0 GB")
    }

    @Test func the_meter_shows_whole_steps_and_never_none_for_a_measured_value() {
        let readings = MetricScale.readings(for: [
            ModelMetrics(speedSeconds: 0.1), ModelMetrics(speedSeconds: 0.25), ModelMetrics(speedSeconds: 100)
        ])

        #expect(readings.map { $0.first?.steps } == [5, 2, 1])
    }

    @Test func a_row_shows_only_what_was_measured_in_one_order() {
        let readings = MetricScale.readings(for: [
            ModelMetrics(accuracy: 0.952, diskBytes: 483_307_520),
            ModelMetrics()
        ])

        #expect(readings[0].map(\.metric) == [.accuracy, .disk])
        #expect(readings[0].map(\.text) == ["95%", "483 MB"])
        #expect(readings[1].isEmpty)
    }
}
