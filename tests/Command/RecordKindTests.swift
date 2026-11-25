import Foundation
import NarrariKit
import Testing

struct RecordKindTests {
    @Test(arguments: RecordKind.allCases)
    func the_line_copied_for_an_agent_is_the_show_command_for_the_same_item(kind: RecordKind) {
        let id = UUID()
        let words = kind.showLine(id).split(separator: " ").map(String.init)

        #expect(words.first == "narrari")
        #expect(Command(arguments: Array(words.dropFirst())) == .show(kind, id, part: nil))
    }
}
