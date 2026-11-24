import Foundation

// Dictation has the model first: a dictation stops a running summary, which starts again after 30 seconds without one.
public final class SummaryService: MeetingStep {
    static let quietBeforeStart: Duration = .seconds(30)

    private let templates: SummaryTemplateFolder
    private let engines: any SummaryEngines
    private let dictation: any DictationActivity
    private let settings: SettingsStore
    private let clock: any Clock<Duration>

    public init(
        templates: SummaryTemplateFolder, engines: any SummaryEngines, dictation: any DictationActivity, settings: SettingsStore,
        clock: any Clock<Duration>
    ) {
        self.templates = templates
        self.engines = engines
        self.dictation = dictation
        self.settings = settings
        self.clock = clock
    }

    public func run(_ id: UUID, in store: MeetingStore) async throws {
        let meeting = try await store.meeting(id)
        let segments = try await store.transcript(of: id)
        guard !segments.isEmpty else {
            Log.event("meeting-summary-no-speech")
            return
        }
        guard !SummaryRequest.isTooShort(segments) else {
            Log.event("meeting-summary-too-short")
            return
        }
        let template = try templates.template(meeting.template, orElse: settings.value(MeetingsSettings.summaryTemplate))
        let request = SummaryRequest(template: template, meeting: meeting, segments: segments, notes: try await store.text(.notes, of: id))
        let lent = try await engine(for: meeting)
        do {
            let summary = try await dictationFirst(id, in: store) { [self] in try await ask(lent.engine, request) }
            let previous = try await store.text(.summary, of: id)
            if !previous.isEmpty { try await store.write(previous, to: .previousSummary, of: id) }
            try await store.write(summary, to: .summary, of: id)
            let model = lent.engine.runsInApp ? ModelReference(lent.engine.name).displayName : "\(lent.engine.name) on the outside service"
            try await store.update(id) { $0.summaryMadeWith = model }
            if Self.takesTitle(meeting) { await title(id, in: store, from: summary, with: lent.engine, in: request.language) }
        } catch {
            await lent.release()
            throw error
        }
        await lent.release()
    }

    // Never over a title from the calendar or the user, read again as it is written in case one was typed meanwhile.
    private static func takesTitle(_ meeting: Meeting) -> Bool {
        meeting.title.isEmpty || meeting.titleIsMade
    }

    // A title that fails leaves the meeting as it was; the summary stays done.
    private func title(_ id: UUID, in store: MeetingStore, from summary: String, with engine: any CleanupEngine, in language: String?) async {
        do {
            let made = try await dictationFirst(id, in: store) { [clock] in
                try await withTimeLimit(SummaryTitle.timeLimit, clock: clock) {
                    try await SummaryTitle.make(with: engine, from: summary, in: language)
                }
            }
            guard let made else { throw SummaryError.noTitle }
            try await store.update(id) { meeting in
                guard Self.takesTitle(meeting) else { return }
                meeting.title = made
                meeting.titleIsMade = true
            }
            Log.event("meeting-title-made")
        } catch {
            Log.failure("meeting-title", error: error)
        }
    }

    // A model chosen and since deleted, or a service since removed, gives way to the clean-up model on this Mac.
    private func engine(for meeting: Meeting) async throws -> SummaryEngine {
        let chosen = SummaryModels.resolved(meeting.summaryModel, settings: settings)
        if chosen == SummaryModels.outside, let outside = engines.outside() {
            Log.event("meeting-summary-outside")
            return outside
        }
        if chosen != SummaryModels.outside, let local = await engines.local(chosen) { return local }
        guard let local = await engines.local(nil) else { throw MeetingStepWaiting.cleanupModel }
        return local
    }

    // A reply in a language the meeting was not held in gets one more try, with the language named again.
    private func ask(_ engine: any CleanupEngine, _ request: SummaryRequest) async throws -> String {
        var text = try await reply(of: engine, to: request, instruction: request.instruction)
        if !request.isInMeetingLanguage(text), let insisting = request.insisting {
            Log.event("meeting-summary-language-retry")
            text = try await reply(of: engine, to: request, instruction: insisting)
        }
        if let refusal = request.refusal(of: text) {
            Log.event("meeting-summary-refused")
            throw refusal
        }
        return text
    }

    private func reply(of engine: any CleanupEngine, to request: SummaryRequest, instruction: String) async throws -> String {
        do {
            try await engine.load()
            return try await withTimeLimit(request.timeLimit, clock: clock) {
                try await engine.rewrite(request.material, instruction: instruction, growth: request.budget)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is TimeLimitExceeded {
            Log.event("meeting-summary-timed-out")
            throw SummaryError.timedOut
        } catch CleanupEngineError.replyTooLong {
            throw SummaryError.tooLong
        } catch CleanupEngineError.modelUnavailable {
            throw SummaryError.modelUnavailable
        } catch CleanupEngineError.generationFailed {
            throw SummaryError.modelFailed
        }
    }

    private enum Turn<Value: Sendable>: Sendable {
        case written(Value)
        case dictation
    }

    private func dictationFirst<Value: Sendable>(
        _ id: UUID, in store: MeetingStore, _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if await isDictating() { try await waitForQuiet(id, in: store) }
        while true {
            let turn: Turn<Value> = try await first(
                { .written(try await work()) },
                { [self] in await nextDictation() ? .dictation : nil }
            )
            guard case .written(let value) = turn else {
                Log.event("meeting-summary-gave-way")
                try await waitForQuiet(id, in: store)
                continue
            }
            return value
        }
    }

    private func waitForQuiet(_ id: UUID, in store: MeetingStore) async throws {
        try await mark(id, in: store, Meeting.Step(.waiting, for: .dictation))
        var isQuiet = false
        while !isQuiet {
            for await busy in dictation.updates() where !busy { break }
            try Task.checkCancellation()
            isQuiet = try await first(
                { [clock] in try await clock.sleep(for: Self.quietBeforeStart); return true },
                { [self] in await nextDictation() ? false : nil }
            )
        }
        try await mark(id, in: store, Meeting.Step(.running, since: .now))
    }

    private func isDictating() async -> Bool {
        for await busy in dictation.updates() { return busy }
        return false
    }

    // False when the updates end, which the race reads as no answer rather than as a dictation.
    private func nextDictation() async -> Bool {
        for await busy in dictation.updates() where busy { return true }
        return false
    }

    private func first<Value: Sendable>(
        _ one: @escaping @Sendable () async throws -> Value?, _ other: @escaping @Sendable () async throws -> Value?
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value?.self) { group in
            group.addTask(operation: one)
            group.addTask(operation: other)
            while let next = try await group.next() {
                guard let answer = next else { continue }
                group.cancelAll()
                return answer
            }
            throw CancellationError()
        }
    }

    private func mark(_ id: UUID, in store: MeetingStore, _ step: Meeting.Step) async throws {
        try await store.update(id) { $0.steps.summary = step }
    }
}
