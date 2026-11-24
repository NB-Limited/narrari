import NarrariKit
import Testing

struct LevelMeterTests {
    @Test func rises_faster_than_it_falls() {
        var meter = LevelMeter()
        meter.follow(1, over: 0.05)
        let risen = meter.level
        meter.follow(0, over: 0.05)
        #expect(risen > 0.7)
        #expect(risen - meter.level < 0.3)
    }

    @Test func the_middle_bar_stands_taller_than_the_ends() {
        var meter = LevelMeter()
        meter.follow(0.6, over: 1)
        let heights = meter.bars(at: 0, breathing: false).map(\.height)
        #expect(heights[3] > heights[0])
        #expect(heights[3] > heights[6])
    }

    @Test func quiet_bars_breathe_only_when_motion_is_allowed() {
        let meter = LevelMeter()
        #expect(meter.bars(at: 0.3, breathing: false).allSatisfy { $0.opacity == 1 && $0.height == 0 })
        #expect(meter.bars(at: 0.3, breathing: true).contains { $0.opacity < 1 })
    }
}
