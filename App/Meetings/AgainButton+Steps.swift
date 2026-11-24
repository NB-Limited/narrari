import AppKit
import NarrariKit
import SwiftUI

extension AgainButton {
    init(page: MeetingPage, step: MeetingProcessing.Step, unavailable: String?, action: @escaping (_ from: NSView?) -> Void) {
        self.init(
            names: Self.names(step), isRunning: page.redoing == step, unavailable: unavailable,
            hasLanded: { page.meeting.steps[step].status == .done }, action: action
        )
    }

    private static func names(_ step: MeetingProcessing.Step) -> Names {
        switch step {
        case .transcript: .transcribe
        case .speakers: Names(title: "Find speakers again", resting: "Find speakers again", running: .findingSpeakers, done: "Speakers found again")
        case .summary, .echo: Names(title: "Redo summary", resting: "Redo summary", running: .writingSummary, done: "Summary redone")
        }
    }
}
