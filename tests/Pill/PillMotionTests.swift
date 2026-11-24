import NarrariKit
import Testing

struct PillMotionTests {
    private let transcribing = PillCapsule.working(.transcribing)
    private let cleaning = PillCapsule.working(.cleaning)

    @Test func shrinking_moves_the_shape_only_after_the_content_has_left() {
        let change = PillChange(from: cleaning, to: .done, widths: (147, 36), reduceMotion: false)
        #expect(change.width == .spring)
        #expect(change.widthDelay == PillMotion.out)
        #expect(change.inDelay == PillMotion.out)
        #expect(!change.revealsFromLeading)
    }

    @Test func growing_moves_the_shape_at_once_and_reveals_the_content_from_the_leading_edge() {
        let change = PillChange(from: cleaning, to: transcribing, widths: (147, 151), reduceMotion: false)
        #expect(change.widthDelay == 0)
        #expect(change.inDelay == PillMotion.inDelay)
        #expect(change.revealsFromLeading)
    }

    @Test func leaving_recording_waits_a_beat_but_widens_from_the_release() {
        let change = PillChange(from: .recording(slot: nil), to: transcribing, widths: (126, 151), reduceMotion: false)
        #expect(change.outDelay == PillMotion.releaseBeat)
        #expect(change.widthDelay == 0)
        #expect(change.inDelay == PillMotion.releaseBeat + PillMotion.inDelay)
    }

    @Test func reduce_motion_jumps_the_width_only_once_the_content_has_faded() {
        let change = PillChange(from: cleaning, to: .done, widths: (147, 36), reduceMotion: true)
        #expect(change.width == .step)
        #expect(change.widthDelay == PillMotion.reduced)
        #expect(change.inDelay == PillMotion.reduced)
        #expect(!change.revealsFromLeading)
    }

    @Test func caption_lifts_away_only_when_the_text_landed() {
        #expect(PillChange.captionExit(to: .done) == .lift)
        #expect(PillChange.captionExit(to: .notice(PillLabel(.discarded))) == .fade)
        #expect(PillChange.captionExit(to: nil) == .fade)
    }

    @Test func the_working_dots_pulse_one_after_another_and_never_go_dark() {
        let lag = PillMotion.dotsStagger * PillMotion.dotsPeriod
        for time in stride(from: 0.0, to: 2, by: 0.05) {
            #expect(abs(PillMotion.dotOpacity(1, at: time + lag) - PillMotion.dotOpacity(0, at: time)) < 1e-9)
            #expect(PillMotion.dotOpacity(2, at: time) >= PillMotion.dotsLow)
        }
    }
}
