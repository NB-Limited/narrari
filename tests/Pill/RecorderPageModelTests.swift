import NarrariKit
import Testing

@MainActor
struct RecorderPageModelTests {
    private let settings = ThrowawaySettings()

    private func plainPage() -> RecorderPageModel {
        RecorderPageModel(settings: settings.mirror, canMute: { true })
    }

    @Test func choosing_a_sound_keeps_it_and_plays_it_once() async {
        let sounds = FakeSounds()
        let page = RecorderPageModel(settings: settings.mirror, canMute: { true }, preview: sounds.preview)
        #expect(page.soundSet == .trace)

        page.chooseSound(.wood)
        await until { !sounds.previewed.isEmpty }

        #expect(settings.store.value(DictationSettings.soundSet) == .wood)
        #expect(sounds.previewed == [.wood])
    }

    @Test func a_sound_shows_as_playing_until_its_preview_ends() async {
        let gate = Gate()
        let page = RecorderPageModel(settings: settings.mirror, canMute: { true }, preview: { _ in
            try? await gate.pass()
        })

        page.previewSound(.wood)
        #expect(page.playingSound == .wood)
        await gate.waitForArrivals(1)
        gate.open()

        await until { page.playingSound == nil }
    }

    @Test func choosing_a_preset_colour_stores_its_name() {
        let page = plainPage()

        page.pillColour = .amber

        #expect(settings.defaults.string(forKey: PillSettings.colour.key) == "amber")
        #expect(plainPage().pillColour == .amber)
    }

    @Test func unknown_stored_colour_reads_as_the_default_preset() {
        settings.defaults.set("violet", forKey: PillSettings.colour.key)

        #expect(plainPage().pillColour == PillSettings.colour.defaultValue)
    }
}
