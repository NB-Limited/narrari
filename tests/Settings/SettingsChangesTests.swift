import NarrariKit
import Testing

struct SettingsChangesTests {
    @Test(.timeLimit(.minutes(1)), arguments: [SpeechSettings.remoteSizeLimitBytes.key, PromptStore.changeKey, PeoplePageModel.changeKey])
    func write_announced_by_another_process_wakes_a_listener(key: String) async {
        let relay = SettingsChanges.followOutsideWrites()
        defer { relay.cancel() }
        var listener = SettingsChanges.updates(of: [key]).makeAsyncIterator()

        SettingsChanges.postOutside(key)

        #expect(await listener.next() != nil)
    }
}
