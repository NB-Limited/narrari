import Foundation

// Silence from the start means the microphone delivers nothing; silence after the first sound is a pause.
extension DictationSession {
    static let silenceWait: Duration = .seconds(2)

    func watchForSilence() {
        endSilenceWatch()
        silenceWatch = Task { [weak self, clock] in
            // A sleep that ended just before the dictation did still resumes, so cancellation is checked after it.
            guard (try? await clock.sleep(for: Self.silenceWait)) != nil, !Task.isCancelled, let self, !recorder.hasHeardSound
            else { return }
            silentMicrophone = recorder.microphoneName ?? "the microphone"
            Log.event("microphone-no-sound")
        }
    }

    func soundArrived() {
        guard phase == .recording else { return }
        let wasSilent = silentMicrophone != nil
        endSilenceWatch()
        if wasSilent { Log.event("microphone-sound-arrived") }
    }

    func endSilenceWatch() {
        silenceWatch?.cancel()
        silenceWatch = nil
        silentMicrophone = nil
    }
}
