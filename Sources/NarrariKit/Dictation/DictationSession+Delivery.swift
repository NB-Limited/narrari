import Foundation

extension DictationSession {
    // A hung pass ends by itself well past any real one: Parakeet runs many times faster than the audio plays.
    private static let transcriptionFloor: Duration = .seconds(30)

    func deliver(_ samples: [Float], for dictation: Dictation, releasedAt: TimeInterval) async {
        guard samples.count >= SpeechAudio.minimumSamples else {
            Log.event("discard-too-little-audio")
            show(.nothingHeard)
            return finish(.discarded)
        }
        guard let transcript = await transcriptOrFailure(of: samples, for: dictation) else { return finish(.failed) }
        let fallback = transcript.fallbackReason
        if let fallback { show(.speechFallback(fallback)) }
        guard !transcript.text.isEmpty else {
            Log.event("discard-nothing-heard")
            show(.nothingHeard)
            return finish(.discarded, speechFallback: fallback)
        }
        if !liveText.isEmpty { liveText = transcript.text }

        let started = now()
        let result = await cleanUp(transcript.text, for: dictation)
        Log.timing("cleanup", seconds: now() - started)
        if let reason = result.cleanup.reason { Self.logCleanupNotRun(reason) }
        if result.cleanup.status == .skipped, let reason = result.cleanup.reason, reason != .nothingToClean {
            show(.cleanupSkipped(reason))
        }
        guard !result.finalText.isEmpty else {
            Log.event("discard-nothing-left")
            show(.nothingHeard)
            return finish(.discarded, result: result, speechFallback: fallback)
        }

        phase = .pasting
        let outcome = await paster.paste(result.finalText)
        Log.timing("release-to-paste", seconds: now() - releasedAt)
        if let notice = Notice(outcome) {
            show(notice)
            finish(.copied, result: result, speechFallback: fallback)
        } else {
            finish(.pasted, result: result, speechFallback: fallback)
        }
    }

    // Nil when the pass failed or Escape stopped it, after saying why.
    private func transcriptOrFailure(of samples: [Float], for dictation: Dictation) async -> Transcript? {
        do {
            guard let heard = try await transcribe(samples, with: dictation.transcriber) else {
                Log.event("transcription-stopped")
                return nil
            }
            return heard
        } catch is TimeLimitExceeded {
            Log.event("transcription-timed-out")
            show(.transcriptionFailed)
        } catch TranscriberError.modelUnavailable {
            show(.modelUnavailable)
        } catch {
            show(.transcriptionFailed)
        }
        return nil
    }

    // Nil when Escape stopped it. No limit while the speech model loads: a download takes minutes, and Escape stops the wait.
    private func transcribe(_ samples: [Float], with transcriber: any Transcriber) async throws -> Transcript? {
        let limit = modelState == .ready
            ? Self.transcriptionFloor + .seconds(Double(samples.count) / SpeechAudio.sampleRate)
            : nil
        let started = now()
        let transcript = try await stoppable { [clock] in
            guard let limit else { return try await transcriber.transcribe(samples: samples) }
            return try await withTimeLimit(limit, clock: clock) { try await transcriber.transcribe(samples: samples) }
        }
        if transcript != nil { Log.timing("transcription", seconds: now() - started) }
        return transcript
    }

    // Escape stops the rewrite and the words go out as spoken, recorded like the clean-up key pressed while recording.
    private func cleanUp(_ text: String, for dictation: Dictation) async -> TextPipeline.Result {
        guard dictation.cleanup == .on else {
            return await pipeline.run(text, prompt: dictation.prompt, cleanup: dictation.cleanup)
        }
        phase = .cleaning
        let prompt = dictation.prompt
        if let result = try? await stoppable({ [pipeline] in await pipeline.run(text, prompt: prompt, cleanup: .on) }) {
            return result
        }
        Log.event("cleanup-stopped")
        return await pipeline.run(text, prompt: prompt, cleanup: .off(.hotkey))
    }

    private static func logCleanupNotRun(_ reason: CleanupResult.Reason) {
        switch reason {
        case .timedOut: Log.event("cleanup-not-run-timed-out")
        case .modelLoading: Log.event("cleanup-not-run-model-loading")
        case .modelUnavailable: Log.event("cleanup-not-run-model-unavailable")
        case .engineFailed: Log.event("cleanup-not-run-engine-failed")
        case .emptyReply: Log.event("cleanup-not-run-empty-reply")
        case .replyTooLong: Log.event("cleanup-not-run-reply-too-long")
        case .unlikeDictation: Log.event("cleanup-not-run-unlike-dictation")
        case .notSetUp: Log.event("cleanup-not-run-not-set-up")
        case .nothingToClean: Log.event("cleanup-not-run-nothing-to-clean")
        case .switchedOff: Log.event("cleanup-not-run-switched-off")
        case .hotkey: Log.event("cleanup-not-run-hotkey")
        case .skippedLanguage: Log.event("cleanup-not-run-skipped-language")
        }
    }

    // Escape is live for the whole step. Stopping cancels the work and returns nil at once; a late result goes nowhere.
    private func stoppable<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value? {
        let step = Task { try await firstToFinish(work) }
        stopStep = { step.cancel() }
        hotkeys.setRecordingKeys(.escape)
        defer {
            stopStep = nil
            hotkeys.setRecordingKeys(.off)
        }
        do {
            return try await step.value
        } catch where step.isCancelled {
            return nil
        }
    }

    func finish(
        _ outcome: Outcome,
        result: TextPipeline.Result? = nil,
        speechFallback: SpeechFallbackReason? = nil
    ) {
        let historyOutcome: HistoryEntry.Outcome
        switch outcome {
        case .pasted:
            Log.event("dictation-pasted")
            historyOutcome = .pasted
            showDone()
        case .copied:
            Log.event("dictation-copied")
            historyOutcome = .clipboard
        case .discarded:
            Log.event("dictation-discarded")
            historyOutcome = .discarded
        case .failed:
            Log.event("dictation-failed")
            historyOutcome = .failed
        }
        // A dictation dropped inside the shortcut window never counted as one, so it leaves no history and no audio.
        if let dictation, !dictation.isConfirmed, outcome == .discarded {
            removeAudio(of: dictation.id)
        } else if let dictation {
            var final = entry(for: dictation, audioFile: HistoryEntry.audioFileName(for: dictation.id), outcome: historyOutcome)
            if let result {
                final.fill(with: result)
                final.speechModel = speechFallback == nil ? dictation.transcriber.name : transcriber.name
            }
            final.speechFallback = speechFallback?.rawValue
            record(final)
            announceHistoryChange()
        }
        if dictation != nil { pipeline.releaseCleanupModel() }
        dictation = nil
        liveText = ""
        phase = .idle
    }
}
