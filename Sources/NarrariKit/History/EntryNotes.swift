import Foundation

extension HistoryEntry {
    public var isCleanupSkipped: Bool {
        cleanup.status == CleanupResult.Status.skipped.rawValue
            && cleanup.reason != CleanupResult.Reason.nothingToClean.rawValue
    }

    public var needsTranscription: Bool {
        finalText.isEmpty && (outcome == .failed || outcome == .discarded)
    }

    public var cleanupNote: String? {
        guard let reason = CleanupResult.Reason(rawValue: cleanup.reason) else { return nil }
        switch reason {
        case .modelLoading: return "Clean-up skipped: model still loading"
        case .modelUnavailable: return "Clean-up skipped: model not loaded"
        case .timedOut: return "Clean-up skipped: took too long"
        case .engineFailed: return "Clean-up skipped: it failed"
        case .emptyReply, .replyTooLong, .unlikeDictation: return "Clean-up skipped: unusable reply"
        case .notSetUp: return "Clean-up skipped: service not set up"
        case .switchedOff: return "Clean-up off"
        case .hotkey: return "Clean-up off for this dictation"
        case .skippedLanguage: return "Clean-up off for this language"
        case .nothingToClean: return nil
        }
    }

    // The heard text against the final, word by word; nil unless clean-up ran and changed a word.
    public var cleanupEdits: [TextDiff.Segment]? {
        guard cleanup.status == CleanupResult.Status.cleaned.rawValue, !rawText.isEmpty else { return nil }
        let segments = TextDiff.words(from: rawText, to: finalText)
        return segments.contains { $0.kind != .kept } ? segments : nil
    }

    public var speechFallbackNote: String? {
        speechFallback.flatMap(SpeechFallbackReason.init(rawValue:)).map { Notice.speechFallback($0).message }
    }

    public var outcomeNote: String? {
        switch outcome {
        case .clipboard: "Copied to the clipboard, not pasted"
        case .failed where finalText.isEmpty: "Not transcribed. The audio is kept."
        case .discarded where finalText.isEmpty: "Discarded. The audio is kept."
        case .discarded: "Discarded, not pasted"
        default: nil
        }
    }

    public func madeWith(appName: String) -> String? {
        let cleanedBy = cleanup.status == CleanupResult.Status.cleaned.rawValue && !cleanup.model.isEmpty
            ? "clean-up by \(cleanup.model.split(separator: "/").last.map(String.init) ?? cleanup.model)"
            : nil
        let models = [speechModel, cleanedBy].compactMap { $0 }.joined(separator: ", ")
        var sentences = models.isEmpty ? [] : [models + "."]
        if cleanup.status == CleanupResult.Status.off.rawValue, let note = cleanupNote {
            sentences.append(note + ".")
        }
        switch outcome {
        case .pasted: sentences.append("Pasted into \(appName).")
        case .clipboard: sentences.append("Copied to the clipboard.")
        default: break
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
