import Foundation

// The work after a meeting as the page shows it: a row a step, and what each tab says while it has nothing to show.
extension MeetingPage {
    public struct StepRow: Identifiable, Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            case retry
            // Downloads what the step waits for, then carries on.
            case download
        }

        public let id: MeetingProcessing.Step
        public let name: String
        public let work: WorkState
        public let action: Action?
        // Read in place of the work's line: "Not needed", or what the model it waits for takes to download.
        public let note: String?

        init(_ id: MeetingProcessing.Step, _ work: WorkState, action: Action? = nil, note: String? = nil) {
            self.id = id
            name = MeetingPage.name(id)
            self.work = work
            self.action = action
            self.note = note
        }

        public func text(at now: Date) -> String {
            note ?? work.label(at: now)
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
        return switch state.status {
        case .done where segments.isEmpty && meeting.steps.transcript.status == .done: "No speech was heard."
        case .done: own == .summary && SummaryRequest.isTooShort(segments) ? "Too short to summarise. The transcript holds every word." : nil
        case .running: own == .speakers ? "Speakers are being found." : "The \(Self.name(own).lowercased()) is being written."
        case .failed: own == .speakers ? "Speakers could not be told apart." : "The \(Self.name(own).lowercased()) could not be written."
        case .waiting where state.waiting != nil: state.waiting.map { "\($0.label)." }
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

    static func activity(_ step: MeetingProcessing.Step) -> WorkState.Activity {
        switch step {
        case .transcript: .transcribing
        case .echo: .checkingForEcho
        case .speakers: .findingSpeakers
        case .summary: .writingSummary
        }
    }

    private func row(_ step: MeetingProcessing.Step) -> StepRow {
        let state = meeting.steps[step]
        if state.status == .waiting, let reason = state.waiting, !reason.models.isEmpty { return modelRow(step, reason) }
        return switch state.status {
        case .done: StepRow(step, .done, note: step == .echo && !hasCleanedTrack ? "Not needed" : nil)
        case .running: runningRow(step, since: state.since)
        case .failed: failedRow(step, step.problem(state.problem))
        case .waiting: StepRow(step, .waiting(state.waiting ?? .turn))
        }
    }

    private func failedRow(_ step: MeetingProcessing.Step, _ problem: Problem) -> StepRow {
        StepRow(step, .failed(problem), action: problem.canRetry ? .retry : nil)
    }

    private func runningRow(_ step: MeetingProcessing.Step, since: Date?) -> StepRow {
        let fraction = step == .transcript ? progress.fractions[meeting.id] : nil
        return StepRow(step, .working(Self.activity(step), progress: fraction, since: since))
    }

    // Downloading with its share of the bytes; a failed download says so and offers Try again.
    private func modelRow(_ step: MeetingProcessing.Step, _ reason: WaitReason) -> StepRow {
        let needed = reason.models
        let statuses = needed.map(models.status(of:))
        let failure = statuses.lazy.compactMap { status -> Problem? in if case .failed(let problem) = status { problem } else { nil } }.first
        if let failure { return StepRow(step, .failed(failure), action: .download) }
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
            return StepRow(step, .waiting(reason), action: .download, note: reason.label + size)
        }
        return StepRow(step, .working(.downloading, progress: landed / total))
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
}
