import Foundation

extension DictationSession {
    func endFeedback(playingStopSound: Bool) {
        guard isListening else { return }
        isListening = false
        queueFeedback { [sounds, media] in
            await media.restoreOutput()
            if playingStopSound { await sounds.play(.stop) }
        }
    }

    // Start and end feedback run in order, so a quick stop never unmutes before the mute has happened.
    func queueFeedback(_ work: @escaping @MainActor () async -> Void) {
        let previous = feedback
        feedback = Task {
            await previous?.value
            await work()
        }
    }

    func show(_ notice: Notice) {
        self.notice = notice
        noticeExpiry?.cancel()
        guard !notice.isError else { return }
        noticeExpiry = Task { [weak self, clock] in
            guard (try? await clock.sleep(for: Self.noticeDuration)) != nil else { return }
            self?.notice = nil
        }
    }

    func clearError() {
        guard let notice, notice.isError else { return }
        self.notice = nil
    }

    func showDone() {
        isDone = true
        doneExpiry?.cancel()
        doneExpiry = Task { [weak self, clock] in
            guard (try? await clock.sleep(for: Self.doneHold)) != nil else { return }
            self?.isDone = false
        }
    }

    func microphoneFailed(_ error: any Error) {
        switch error as? RecorderError {
        case .microphoneDenied:
            Log.failure("start-microphone-denied")
            show(.microphoneDenied)
        case .microphoneAccessRequested:
            Log.failure("start-microphone-access-requested")
            show(.microphoneAccessRequested)
        case .noInput:
            Log.failure("start-microphone-no-input")
            show(.microphoneUnavailable)
        case .startFailed:
            Log.failure("start-microphone-failed")
            show(.microphoneUnavailable)
        case nil:
            Log.failure("start-microphone-unknown", error: error)
            show(.microphoneUnavailable)
        }
    }
}
