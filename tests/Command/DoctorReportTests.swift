import NarrariKit
import Testing

struct DoctorReportTests {
    private var facts = DoctorFacts(
        app: "0.1.0 (1)", system: "macOS Version 26.1", mac: "Mac16,8, 48 GB memory", runningSince: "2026-11-20 16:30:09",
        microphone: .init(.allowed, at: "2026-11-20 16:30:09"), accessibility: .init(true, at: "2026-11-20 16:30:09"),
        shortcutTap: .init(.working, at: "2026-11-20 16:30:09"),
        inputs: [.init(name: "MacBook Pro Microphone", transport: .builtIn, isDefault: true, isUsed: true)],
        isChosenMicrophoneMissing: false, output: .init(name: "MacBook Pro Speakers", canMute: true),
        speech: .init(name: "Parakeet Ultra", bytesOnDisk: 642_560_000), speechService: .off,
        cleanup: .onThisMac(.init(name: "Qwen3.5 2B", bytesOnDisk: 2_689_744_896)),
        meetingModels: [.init(name: "Silero VAD", bytesOnDisk: 2_000_000), .init(name: "LocalVQE v1.3", bytesOnDisk: 0)],
        dataBytes: 3_500_000_000, history: .init(dictations: 12, bytes: 4_000_000), meetings: .init([]), canSeeScreenWatch: true
    )

    @Test mutating func a_problem_marks_its_line_and_fails_the_command() {
        let healthy = DoctorReport(facts: facts).reply
        #expect(healthy.status == 0)
        #expect(!healthy.output.contains("\n!"))
        #expect(healthy.output.hasSuffix("No problems found.\n"))

        facts.microphone = .init(.denied, at: "2026-11-20 16:30:09")
        let refused = DoctorReport(facts: facts).reply

        #expect(refused.status == 1)
        #expect(refused.output.contains("\n! Microphone access: turned off in System Settings, reported by Narrari at 2026-11-20 16:30:09\n"))
        #expect(refused.output.hasSuffix("1 problem, marked with !.\n"))
    }

    @Test mutating func a_mac_that_cannot_tell_when_the_screen_is_shared_is_named_without_failing() {
        facts.canSeeScreenWatch = false
        let reply = DoctorReport(facts: facts).reply

        #expect(reply.status == 0)
        #expect(reply.output.contains("\nScreen sharing: this macOS does not say when the screen is shared, so only the window setting hides"))
    }

    @Test mutating func meetings_are_counted_by_where_each_unfinished_one_stands_without_their_titles() {
        func meeting(_ title: String, state: Meeting.State = .ready, done: Int = 0, failing: Bool = false) -> Meeting {
            var meeting = Meeting(title: title, startedAt: .now, app: "", source: .call, template: "general", state: state)
            for step in [\Meeting.Steps.echo, \.transcript, \.speakers, \.summary].prefix(done) { meeting.steps[keyPath: step] = .init(.done) }
            if failing { meeting.steps.summary = .init(.failed, problem: SummaryError.modelFailed.problem.code) }
            return meeting
        }
        facts.meetings = .init([
            meeting("Budget with Ana Petrova", done: 4), meeting("Weekly sync", state: .recording),
            meeting("Hiring", done: 1), meeting("Roadmap", done: 1), meeting("Launch", done: 3, failing: true)
        ])

        let reply = DoctorReport(facts: facts).reply

        #expect(reply.status == 0)
        #expect(reply.output.contains("""
            Meetings: 5 meetings, 4 unfinished:
              1 still recording, or stopped by a quit or crash before it was saved
              2 at the transcript
              1 failed at the summary
            """))
        #expect(reply.output.contains("Meeting models:\n  Silero VAD, on this Mac, 2 MB\n  LocalVQE v1.3, not downloaded\n"))
        #expect(!["Budget", "Ana", "Weekly", "Hiring", "refused"].contains { reply.output.contains($0) })
    }

    @Test mutating func the_last_meeting_losing_part_of_a_track_is_a_problem_line() {
        var older = Meeting(title: "Budget", startedAt: .now.addingTimeInterval(-3_600), app: "", source: .call, template: "general", state: .ready)
        older.microphoneLostPercent = 80
        var last = Meeting(title: "Weekly sync", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        last.systemLostPercent = 42
        facts.meetings = .init([older, last])

        let reply = DoctorReport(facts: facts).reply

        #expect(reply.status == 1)
        #expect(reply.output.contains("! Last meeting: 42% of its system sound track was not recorded"))
        #expect(!reply.output.contains("microphone track"))
    }

    @Test mutating func right_hand_shortcuts_that_macos_refused_are_a_problem() {
        facts.shortcutTap = .init(.notWorking, at: "2026-11-20 16:30:09")
        let reply = DoctorReport(facts: facts).reply

        #expect(reply.status == 1)
        #expect(reply.output.contains("\n! Right-hand shortcuts: not working, macOS refused Narrari's key listener, reported by Narrari at"))
    }
}
