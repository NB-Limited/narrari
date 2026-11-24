import Foundation
import NarrariKit
import Observation
import Testing

// The audio output: records which file each sound would come from and what was played.
@MainActor
@Observable
private final class FakeSpeaker {
    private(set) var loaded: [SoundSet] = []
    private(set) var played: [String] = []
    var missing: Set<String> = []

    func load(_ set: SoundSet, _ sound: Sound) -> (any SoundClip)? {
        loaded.append(set)
        let name = set.fileName(for: sound)
        guard !missing.contains(name) else { return nil }
        return Clip { [weak self] in self?.played.append(name) }
    }

    private final class Clip: SoundClip {
        let duration: TimeInterval = 0.1
        private let onPlay: () -> Void

        init(onPlay: @escaping () -> Void) {
            self.onPlay = onPlay
        }

        func play() -> Bool {
            onPlay()
            return true
        }
    }
}

@MainActor
struct SoundsTests {
    private let settings = ThrowawaySettings()
    private let speaker = FakeSpeaker()
    private let clock = TestClock()

    private func sounds() -> Sounds {
        Sounds(settings: settings.store, clock: clock, load: speaker.load)
    }

    // Sounds waits out each sound on the clock, so the test moves the clock past it.
    private func play(_ sound: Sound, on sounds: Sounds) async {
        let playing = Task { await sounds.play(sound) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await playing.value
    }

    @Test func plays_trace_until_another_set_is_chosen() async {
        let sounds = sounds()

        await play(.start, on: sounds)

        #expect(speaker.played == ["trace-start.wav"])
    }

    @Test func a_new_set_is_loaded_when_chosen_and_plays_for_every_moment() async {
        let sounds = sounds()

        settings.store.set(.wood, for: DictationSettings.soundSet)
        await until { speaker.loaded.contains(.wood) }
        let loadsBeforePlaying = speaker.loaded.count
        for sound in Sound.allCases { await play(sound, on: sounds) }

        #expect(speaker.played == ["wood-start.wav", "wood-stop.wav", "wood-discard.wav"])
        #expect(speaker.loaded.count == loadsBeforePlaying)
    }

    @Test func nothing_plays_with_the_switch_off() async {
        settings.store.set(false, for: DictationSettings.playsSounds)
        let sounds = sounds()

        for sound in Sound.allCases { await sounds.play(sound) }

        #expect(speaker.played.isEmpty)
    }

    @Test func a_missing_sound_is_silent_and_the_others_still_play() async {
        speaker.missing = ["trace-start.wav"]
        let sounds = sounds()

        await sounds.play(.start)
        await play(.stop, on: sounds)

        #expect(speaker.played == ["trace-stop.wav"])
    }

    @Test func preview_plays_start_then_stop_and_keeps_the_chosen_set() async {
        let sounds = sounds()

        let preview = Task { await sounds.preview(.bell) }
        for _ in 0..<3 {
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(1))
        }
        await preview.value

        #expect(speaker.played == ["bell-start.wav", "bell-stop.wav"])
        #expect(settings.store.value(DictationSettings.soundSet) == .trace)
    }

    @Test func every_shipped_set_has_all_three_sounds() {
        for set in SoundSet.allCases {
            for sound in Sound.allCases {
                let clip = Sounds.loadFile(set, sound)
                #expect((clip?.duration ?? 0) > 0, "\(set.fileName(for: sound)) is missing or unreadable")
            }
        }
    }
}
