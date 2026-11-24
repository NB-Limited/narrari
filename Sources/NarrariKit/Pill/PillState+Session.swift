import Foundation

extension PillState {
    // Pasting has no look of its own, so it maps to nothing and the pill keeps what it showed.
    @MainActor
    public init?(_ session: DictationSession) {
        let notice = session.notice.map(PillLabel.init)
        let caption = session.liveText.isEmpty ? nil : session.liveText
        switch session.phase {
        case .recording where session.isListening:
            let slot = notice ?? (session.isModelLoading ? .modelLoading : nil)
            self.init(capsule: .recording(slot: slot), caption: caption, silentMicrophone: session.silentMicrophone)
        case .transcribing, .cleaning:
            if let notice {
                self.init(capsule: .notice(notice))
            } else if session.isWaitingForModel {
                self.init(capsule: .notice(.modelLoading))
            } else {
                self.init(capsule: .working(session.phase == .cleaning ? .cleaning : .transcribing), caption: caption)
            }
        case .idle, .recording, .pasting:
            if let notice {
                self.init(capsule: .notice(notice))
            } else if session.isDone {
                self.init(capsule: .done)
            } else {
                return nil
            }
        }
    }
}
