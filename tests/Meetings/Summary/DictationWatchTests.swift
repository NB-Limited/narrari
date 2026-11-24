import NarrariKit
import Testing

@MainActor
struct DictationWatchTests {
    @Test func reports_a_dictation_from_the_key_going_down_until_the_text_has_landed() async {
        let rig = SessionRig()
        let watch = DictationWatch()
        watch.session = rig.session
        var updates = watch.updates().makeAsyncIterator()
        #expect(await updates.next() == false)

        await rig.pressAndConfirm()
        #expect(await updates.next() == true)

        rig.release()
        await until { rig.session.phase == .idle }
        var last: Bool? = true
        while last == true { last = await updates.next() }
        #expect(last == false)
    }

    @Test func nothing_is_in_progress_before_the_session_exists() async {
        var updates = DictationWatch().updates().makeAsyncIterator()
        #expect(await updates.next() == false)
        #expect(await updates.next() == nil)
    }
}
