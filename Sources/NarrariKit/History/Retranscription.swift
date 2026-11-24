import Foundation

public enum RetranscriptionError: Error, Equatable {
    case audioMissing
    case nothingHeard
    case cleanupNotRun(CleanupResult.Reason)
}

public struct Retranscription: Sendable {
    private let history: HistoryStore
    private let transcription: FileTranscription
    private let pipeline: TextPipeline
    private let modes: ModeStore
    private let settings: SettingsStore

    public init(
        history: HistoryStore,
        pipeline: TextPipeline,
        transcription: FileTranscription,
        modes: ModeStore,
        settings: SettingsStore
    ) {
        self.history = history
        self.transcription = transcription
        self.pipeline = pipeline
        self.modes = modes
        self.settings = settings
    }

    // Appends a line with the same id, so the reader shows the new texts and the old line stays in the file.
    public func run(_ entry: HistoryEntry) async throws -> HistoryEntry {
        await pipeline.holdCleanupModel()
        do {
            let updated = try await rerun(entry)
            await pipeline.releaseCleanupModel()
            return updated
        } catch {
            await pipeline.releaseCleanupModel()
            throw error
        }
    }

    // The heard text through the prompt chosen, or as spoken, saved like run(_:) so the old text stays in the file.
    // Clean-up switched off is reported, never turned on, and only a model already on this Mac is used.
    public func cleanUp(_ entry: HistoryEntry, with choice: CleanupChoice) async throws -> HistoryEntry {
        let result: TextPipeline.Result
        if let prompt = choice.prompt {
            guard settings.value(CleanupSettings.isEnabled) else { throw RetranscriptionError.cleanupNotRun(.switchedOff) }
            await pipeline.holdCleanupModel()
            result = await pipeline.run(heard: entry.rawText, prompt: prompt)
            await pipeline.releaseCleanupModel()
            guard result.cleanup.status == .cleaned else {
                throw RetranscriptionError.cleanupNotRun(result.cleanup.reason ?? .engineFailed)
            }
        } else {
            result = await pipeline.run(heard: entry.rawText, prompt: nil)
        }
        var updated = entry
        updated.fill(with: result)
        try await history.update(updated)
        return updated
    }

    public func prompts() -> [Prompt] {
        pipeline.allPrompts()
    }

    // A file becomes a new entry, its audio kept as a dictation's is; a failure or cancel leaves neither behind.
    public func run(
        file url: URL, as entry: HistoryEntry, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> HistoryEntry {
        do {
            let kept = try await history.audioDestination(for: entry.id)
            let transcript = try await transcription.run(url, keepingAudioAt: kept, progress: progress)
            guard !transcript.text.isEmpty else { throw RetranscriptionError.nothingHeard }
            var saved = entry
            saved.durationMs = Int((transcript.audioSeconds * 1000).rounded())
            fill(&saved, with: pipeline.file(transcript.text))
            try Task.checkCancellation()
            try await history.append(saved)
            Log.event("history-file-saved")
            return saved
        } catch {
            try? await history.removeAudio(for: entry.id)
            throw error
        }
    }

    private func rerun(_ entry: HistoryEntry) async throws -> HistoryEntry {
        let audio = history.audioURL(for: entry.id)
        guard FileManager.default.fileExists(atPath: audio.path) else { throw RetranscriptionError.audioMissing }
        let transcript = try await transcription.run(audio) { _ in }
        guard !transcript.text.isEmpty else { throw RetranscriptionError.nothingHeard }

        let result: TextPipeline.Result
        if entry.file != nil {
            result = pipeline.file(transcript.text)
        } else {
            let mode = mode(for: entry)
            let isCleanupOn = mode.isCleanupOn && settings.value(CleanupSettings.isEnabled)
            result = await pipeline.run(
                transcript.text, prompt: pipeline.prompt(id: mode.promptID), cleanup: isCleanupOn ? .on : .off(.switchedOff)
            )
        }
        var updated = entry
        fill(&updated, with: result)
        updated.speechFallback = nil
        try await history.update(updated)
        Log.event("history-entry-retranscribed")
        return updated
    }

    private func fill(_ entry: inout HistoryEntry, with result: TextPipeline.Result) {
        entry.fill(with: result)
        entry.speechModel = transcription.modelName
    }

    private func mode(for entry: HistoryEntry) -> Mode {
        let book: ModeBook
        do {
            book = try modes.load()
        } catch {
            Log.failure("modes-load", error: error)
            book = ModeBook()
        }
        return book.modes.first { $0.name == entry.mode } ?? book.defaultMode(for: entry.app)
    }
}
