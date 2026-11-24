import Foundation
import NarrariKit
import Testing

@MainActor
struct ClipboardTests {
    @Test func copy_replaces_the_clipboard_with_the_text_alone() {
        let pasteboard = FakePasteboard([[PasteboardEntry(type: .tiff, data: Data([0x4D, 0x4D]))]])

        Clipboard.copy("Tell Ivan the report is late.", to: pasteboard)

        #expect(pasteboard.items().count == 1)
        #expect(pasteboard.text == "Tell Ivan the report is late.")
    }
}
