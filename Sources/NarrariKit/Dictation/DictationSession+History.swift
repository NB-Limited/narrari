import Foundation

extension DictationSession {
    func entry(
        for dictation: Dictation, audioFile: String, outcome: HistoryEntry.Outcome? = nil
    ) -> HistoryEntry {
        var entry = HistoryEntry(
            id: dictation.id,
            startedAt: dictation.startedAt,
            durationMs: dictation.durationMs,
            app: dictation.app,
            audioFile: audioFile,
            outcome: outcome
        )
        entry.mode = dictation.modeName
        entry.audioFailure = dictation.audioProblem?.code
        return entry
    }

    func record(_ entry: HistoryEntry) {
        queueHistory("history-append") { try await $0.append(entry) }
    }

    func announceHistoryChange() {
        let writes = historyWrites
        Task { [historyChangeSink] in
            await writes?.value
            historyChangeSink.yield()
        }
    }

    func removeAudio(of id: UUID) {
        queueHistory("audio-file-delete") { try await $0.removeAudio(for: id) }
    }

    // Writes run one after another, so a dictation's final line never lands before its first.
    private func queueHistory(_ failure: StaticString, _ work: @escaping @Sendable (HistoryStore) async throws -> Void) {
        let previous = historyWrites
        historyWrites = Task { [history] in
            await previous?.value
            do {
                try await work(history)
            } catch {
                Log.failure(failure, error: error)
            }
        }
    }
}
