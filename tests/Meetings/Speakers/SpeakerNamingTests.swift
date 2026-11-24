import Foundation
import NarrariKit
import Testing

struct SpeakerNamingTests {
    @Test func a_clear_match_names_a_near_match_suggests_and_a_far_voice_stays_numbered() {
        let (ana, boris, clara) = (UUID(), UUID(), UUID())
        let between = (SpeakerNaming.clear + SpeakerNaming.near) / 2

        let matches = SpeakerNaming.matches(
            [
                "S1": voicePrint(0, distance: SpeakerNaming.clear - 0.05),
                "S2": voicePrint(1, distance: between),
                "S3": voicePrint(2, distance: SpeakerNaming.near + 0.05)
            ],
            voices: [ana: voicePrint(0), boris: voicePrint(1), clara: voicePrint(2)]
        )

        #expect(matches == ["S1": .named(ana), "S2": .suggested(boris)])
    }

    @Test func two_speakers_never_get_one_name_and_the_closer_keeps_it() {
        let ana = UUID()

        let matches = SpeakerNaming.matches(["S1": voicePrint(0, distance: 0.15), "S2": voicePrint(0, distance: 0.05)], voices: [ana: voicePrint(0)])

        #expect(matches == ["S2": .named(ana), "S1": .suggested(ana)])
    }
}
