import Foundation

extension DictationSession {
    // Ignored while a dictation runs, so the clipboard it saved is never touched.
    public func pasteLast(_ text: String?) async {
        Log.event("paste-last")
        guard phase == .idle else { return Log.event("paste-last-busy") }
        guard let text, !text.isEmpty else {
            Log.event("paste-last-nothing")
            return show(.nothingToPaste)
        }
        let outcome = await paster.paste(text)
        if let notice = Notice(outcome) {
            Log.event("paste-last-copied")
            show(notice)
        } else {
            Log.event("paste-last-pasted")
            clearError()
            showDone()
        }
    }
}
