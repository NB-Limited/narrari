import NarrariKit
import Testing

struct SettingsStoreTests {
    private let settings = ThrowawaySettings()

    @Test func missing_key_reads_as_the_default_for_every_value_type() {
        #expect(settings.store.value(CleanupSettings.isEnabled) == true)
        #expect(settings.store.value(HistorySettings.retentionDays) == 7)
        #expect(settings.store.value(DictationSettings.holdThreshold) == 0.5)
        #expect(settings.store.value(SpeechSettings.localModel) == ParakeetModel.recommended)
    }

    @Test func value_of_the_wrong_type_reads_as_the_default() {
        settings.defaults.set("half a second", forKey: DictationSettings.holdThreshold.key)
        settings.defaults.set(["7"], forKey: HistorySettings.retentionDays.key)

        #expect(settings.store.value(DictationSettings.holdThreshold) == 0.5)
        #expect(settings.store.value(HistorySettings.retentionDays) == 7)
    }

    @Test func written_value_reads_back_and_reset_returns_the_default() {
        settings.store.set(0.8, for: DictationSettings.holdThreshold)
        #expect(settings.store.value(DictationSettings.holdThreshold) == 0.8)

        settings.store.reset(DictationSettings.holdThreshold)
        #expect(settings.store.value(DictationSettings.holdThreshold) == 0.5)
    }

    @Test func choice_is_stored_by_name_and_an_unknown_name_reads_as_the_default() {
        #expect(settings.store.value(PillSettings.look) == .smoked)

        settings.store.set(.solid, for: PillSettings.look)
        #expect(settings.defaults.string(forKey: PillSettings.look.key) == "solid")
        #expect(settings.store.value(PillSettings.look) == .solid)

        settings.defaults.set("frosted", forKey: PillSettings.look.key)
        #expect(settings.store.value(PillSettings.look) == .smoked)
    }

    @Test func write_wakes_a_listener_of_that_key() async {
        let updates = SettingsChanges.updates(of: [SpeechSettings.remoteLanguage.key])
        var listener = updates.makeAsyncIterator()

        settings.store.set("bg", for: SpeechSettings.remoteLanguage)

        #expect(await listener.next() != nil)
    }
}
