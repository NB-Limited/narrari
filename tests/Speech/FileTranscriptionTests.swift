import Foundation
import NarrariKit
import Testing

struct FileTranscriptionTests {
    @Test func progress_passes_on_only_when_the_whole_percent_changes() {
        var steps = FileTranscription.Steps()

        let admitted = (0...10_000).filter { steps.admit(Double($0) / 10_000) }.count

        #expect(admitted == 101)
    }
}
