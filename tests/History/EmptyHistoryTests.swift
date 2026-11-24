import NarrariKit
import Testing

struct EmptyHistoryTests {
    @Test func until_the_speech_model_is_ready_the_page_tells_its_progress_not_how_to_dictate() {
        let downloading = EmptyHistory(model: .preparing(fraction: 0.42, isDownloading: true), hotkey: "Right ⌘", kept: "for 7 days")
        let ready = EmptyHistory(model: .ready, hotkey: "Right ⌘", kept: "for 7 days")

        #expect(downloading.said == "The speech model is downloading.")
        #expect(downloading.heard == "42%. When it is ready, hold Right ⌘ anywhere and speak.")
        #expect(ready.said == "Hold Right ⌘ anywhere and speak.")
        #expect(ready.heard == "The text lands in the app you are typing in, and a copy is kept here for 7 days.")
    }
}
