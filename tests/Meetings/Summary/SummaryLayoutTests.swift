import NarrariKit
import Testing

struct SummaryLayoutTests {
    @Test func bold_marks_go_and_every_list_marker_becomes_a_dash() {
        let reply = "## Action items\n*   **Ana Petrova**: send the plan.\n• Book the room\n  - Call back\nA line with 2 * 3 stays."

        #expect(SummaryLayout.plain(reply) == "## Action items\n- Ana Petrova: send the plan.\n- Book the room\n- Call back\nA line with 2 * 3 stays.")
    }
}
