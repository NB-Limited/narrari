import Foundation
import NarrariKit
import Testing

struct WorkStateTests {
    @Test func a_model_downloading_reads_its_share_and_one_on_this_mac_reads_getting_ready() {
        #expect(ModelState.preparing(fraction: 0.46, isDownloading: true).work.label == "Downloading, 46%")
        #expect(ModelState.preparing(fraction: 0.46, isDownloading: false).work.label == "Getting ready")
        #expect(ModelState.ready.work == .idle)
    }

    @Test func waiting_work_says_what_it_waits_for() {
        #expect(WorkState.waiting(.transcript).label == "Waits for the transcript")
        #expect(WorkState.waiting(.speechModel).label == "Waits for the speech model")
    }

    @Test func work_under_way_reads_its_time_until_a_share_is_known() {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let later = started.addingTimeInterval(40)

        #expect(WorkState.working(.findingSpeakers, since: started).label(at: later) == "Finding speakers, 0:40")
        #expect(WorkState.working(.transcribing, progress: 0.42, since: started).label(at: later) == "Transcribing, 42%")
    }

    @Test func failed_work_carries_its_problem_and_whether_trying_again_helps() {
        let problem = Problem("meeting.echo-failed", "Echo removal failed. Try again.", canRetry: true)
        let failed = WorkState.failed(problem)

        #expect(failed.label == "Echo removal failed. Try again." && failed.problem?.canRetry == true)
    }
}
