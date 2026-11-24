import Foundation

// The work after a meeting as the page shows it: a row a step, and what each tab says while it has nothing to show.
extension MeetingPage {
    public struct StepRow: Identifiable, Sendable, Equatable {
        public enum Look: Sendable, Equatable {
            case done
            case working
            case waiting
            case failed
        }

        public enum Action: Sendable, Equatable {
            case retry
            // Downloads what the step waits for, then carries on.
            case download
        }

        public let id: MeetingProcessing.Step
        public let name: String
        public let look: Look
        public let since: Date?
        public let progress: Double?
        public let action: Action?
        let status: String

        init(
            _ id: MeetingProcessing.Step, look: Look, status: String, since: Date? = nil, progress: Double? = nil, action: Action? = nil
        ) {
            self.id = id
            name = MeetingPage.name(id)
            self.look = look
            self.status = status
            self.since = since
            self.progress = progress
            self.action = action
        }

        // "Writing the transcript, 1:24" while it runs.
        public func text(at now: Date) -> String {
            guard let since else { return status }
            return "\(status), \(MeetingSurfaces.elapsedText(seconds: max(now.timeIntervalSince(since), 0)))"
        }
    }

    // Until every step is done; a failed one stays until it is retried.
    public var steps: [StepRow]? {
        guard !isRecording, MeetingProcessing.Step.allCases.contains(where: { meeting.steps[$0].status != .done }) else { return nil }
        return [MeetingProcessing.Step.transcript, .echo, .speakers, .summary].map(row)
    }

    // After a failure too, so another template or model can be tried.
    public var canRedoSummary: Bool {
        !isRecording && meeting.steps.transcript.status == .done && [.done, .failed].contains(meeting.steps.summary.status)
    }

    // In place of a tab's content while it has none: what it waits for, or why there is none. The steps grid above has the rest.
    public func emptyLine(for tab: Tab) -> String? {
        let own: MeetingProcessing.Step = switch tab {
        case .summary: .summary
        case .transcript: .transcript
        case .speakers: .speakers
        }
        if isRecording {
            return own == .transcript ? nil : own == .summary ? "Comes after the meeting." : "Speakers are found after the meeting."
        }
        if let before = earlier(own) { return "Comes after \(Self.phrase(before))." }
        let state = meeting.steps[own]
        let needed = MeetingStepWaiting.models(for: state.reason)
        return switch state.status {
        case .done where segments.isEmpty && meeting.steps.transcript.status == .done: "No speech was heard."
        case .done: own == .summary && SummaryRequest.isTooShort(segments) ? "Too short to summarise. The transcript holds every word." : nil
        case .running: own == .speakers ? "Speakers are being found." : "The \(Self.name(own).lowercased()) is being written."
        case .failed: own == .speakers ? "Speakers could not be told apart." : "The \(Self.name(own).lowercased()) could not be written."
        case .waiting where !needed.isEmpty: "Waits for the \(Self.phrase(needed))."
        case .waiting where state.reason == SummaryService.waitingReason: "Waits for dictation to finish."
        case .waiting: own == .speakers ? "Speakers are not found yet." : "Not written yet."
        }
    }

    public func tryAgain(_ row: StepRow) async {
        switch row.action {
        case .retry: await retry(row.id)
        case .download: await processing.process(meeting.id)
        case nil: return
        }
        await load()
    }

    static func working(_ step: MeetingProcessing.Step) -> String {
        switch step {
        case .transcript: "Writing the transcript"
        case .echo: "Checking for echo"
        case .speakers: "Finding speakers"
        case .summary: "Writing the summary"
        }
    }

    private func row(_ step: MeetingProcessing.Step) -> StepRow {
        let state = meeting.steps[step]
        let needed = state.status == .waiting ? MeetingStepWaiting.models(for: state.reason) : []
        if !needed.isEmpty { return modelRow(step, needed) }
        return switch state.status {
        case .done: StepRow(step, look: .done, status: step == .echo && !hasCleanedTrack ? "Not needed" : "Done")
        case .running: runningRow(step, since: state.since)
        case .failed: StepRow(step, look: .failed, status: state.reason ?? "Failed", action: .retry)
        case .waiting: StepRow(step, look: .waiting, status: Self.waiting(state.reason))
        }
    }

    private func runningRow(_ step: MeetingProcessing.Step, since: Date?) -> StepRow {
        guard step == .transcript, let fraction = progress.fractions[meeting.id] else {
            return StepRow(step, look: .working, status: Self.working(step), since: since)
        }
        return StepRow(step, look: .working, status: "\(Self.working(step)), \(MetricText.percent(fraction))", progress: fraction)
    }

    // Downloading with its share of the bytes; a failed download says so and offers Try again.
    private func modelRow(_ step: MeetingProcessing.Step, _ needed: [NeededModel]) -> StepRow {
        let statuses = needed.map(models.status(of:))
        let failure = statuses.lazy.compactMap { status -> String? in if case .failed(let reason) = status { reason } else { nil } }.first
        if let failure { return StepRow(step, look: .failed, status: failure, action: .download) }
        let sizes = needed.map(models.size(of:))
        let total = Double(sizes.reduce(0, +))
        let landed = zip(sizes, statuses).reduce(0.0) { sum, pair in
            switch pair.1 {
            case .onThisMac: sum + Double(pair.0)
            case .downloading(let fraction): sum + Double(pair.0) * fraction
            case .notDownloaded, .failed: sum
            }
        }
        guard statuses.contains(where: { if case .downloading = $0 { true } else { false } }), total > 0 else {
            let size = total > 0 ? ", \(MetricText.bytes(Int64(total)))" : ""
            return StepRow(step, look: .waiting, status: "Needs the \(Self.phrase(needed))\(size)", action: .download)
        }
        let fraction = landed / total
        return StepRow(step, look: .working, status: "Downloading, \(MetricText.percent(fraction))", progress: fraction)
    }

    private static func phrase(_ needed: [NeededModel]) -> String {
        switch needed.first {
        case .speech: "speech model"
        case .cleanup: "clean-up model"
        case .meeting(.speakerSplit): "speaker model"
        case .meeting, nil: "echo removal models"
        }
    }

    // Speakers run before the summary so it has their names, but a summary does not wait on speakers that failed.
    private func earlier(_ step: MeetingProcessing.Step) -> MeetingProcessing.Step? {
        let before: [MeetingProcessing.Step] = switch step {
        case .echo: []
        case .transcript: [.echo]
        case .speakers: [.transcript]
        case .summary: [.transcript, .speakers]
        }
        return before.first { meeting.steps[$0].status != .done && !(step == .summary && meeting.steps[$0].status == .failed && $0 == .speakers) }
    }

    private static func phrase(_ step: MeetingProcessing.Step) -> String {
        switch step {
        case .echo: "echo removal"
        case .transcript: "the transcript"
        case .speakers: "the speakers"
        case .summary: "the summary"
        }
    }

    private static func waiting(_ reason: String?) -> String {
        switch reason {
        case MeetingProcessing.Step.echo.waitingReason: "Waits for echo removal"
        case MeetingProcessing.Step.transcript.waitingReason: "Waits for the transcript"
        case let reason?: reason
        case nil: "Waiting"
        }
    }
}
