import Foundation
import NarrariKit
import Testing

struct HaloTests {
    private let perimeter = Halo.perimeter(width: 82, height: 36)

    @Test func the_line_stretches_with_the_level_and_stays_centred_on_the_top_edge() {
        let quiet = Halo.line(loudness: 0, perimeter: perimeter)
        let loud = Halo.line(loudness: 1, perimeter: perimeter)
        #expect(abs((quiet.upperBound - quiet.lowerBound) * perimeter - PillGeometry.haloShortest) < 0.001)
        #expect(abs((loud.upperBound - loud.lowerBound) * perimeter - PillGeometry.haloLongest) < 0.001)
        #expect(abs((loud.lowerBound + loud.upperBound) / 2 - Halo.top) < 0.000_001)
    }

    @Test func the_travelling_light_covers_equal_distances_in_equal_times_and_laps_once_per_lap() {
        let start = Halo.lap(at: 0, perimeter: perimeter).upperBound
        let quarter = Halo.lap(at: PillMotion.haloLap / 4, perimeter: perimeter).upperBound
        let half = Halo.lap(at: PillMotion.haloLap / 2, perimeter: perimeter).upperBound
        #expect(start == Halo.top)
        #expect(abs((half - quarter) - (quarter - start)) < 0.000_001)
        let lapped = Halo.spans(Halo.lap(at: PillMotion.haloLap, perimeter: perimeter))[0]
        let first = Halo.spans(Halo.lap(at: 0, perimeter: perimeter))[0]
        #expect(abs(lapped.lowerBound - first.lowerBound) < 0.000_001)
    }

    @Test func a_stretch_past_the_start_of_the_outline_is_split_there() {
        let spans = Halo.spans(0.9...1.2)
        #expect(spans.count == 2)
        #expect(abs(spans[0].lowerBound - 0.9) < 0.000_001 && spans[0].upperBound == 1)
        #expect(spans[1].lowerBound == 0 && abs(spans[1].upperBound - 0.2) < 0.000_001)
    }

    @Test func done_draws_the_outline_then_fades_and_reduce_motion_lights_it_at_once() {
        #expect(Halo.done(at: PillMotion.haloDraw / 2, reduceMotion: false).lit == 0.5)
        #expect(Halo.done(at: 0, reduceMotion: true).lit == 1)
        #expect(Halo.done(at: PillMotion.haloDraw, reduceMotion: false).brightness == 1)
        #expect(Halo.done(at: PillMotion.haloDraw + PillMotion.haloFade, reduceMotion: false).brightness == 0)
        #expect(.seconds(PillMotion.haloDraw + PillMotion.haloFade) <= DictationSession.doneHold)
    }
}
