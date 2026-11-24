import Foundation

// How a clean-up reply compares with the dictation, in words, so a reply that lost or repeated the speech is not pasted.
public struct ReplyFit: Sendable, Equatable {
    public let transcriptWords: Int
    public let replyWords: Int
    // Share of the dictation's distinct words of three letters or more found in the reply; fillers and repeats drop out.
    public let contentKept: Double
    // Reply words beyond the dictation's own, counted with repeats, per dictation word.
    public let added: Double
    // Reply lines with no word of the dictation, such as a greeting or sign-off nobody said.
    public let unspokenLines: Int

    public init(transcript: String, reply: String) {
        let said = Self.words(transcript)
        let written = Self.words(reply)
        var left = Dictionary(said.map { ($0, 1) }, uniquingKeysWith: +)
        var beyond = 0
        for word in written {
            if left[word, default: 0] > 0 { left[word, default: 0] -= 1 } else { beyond += 1 }
        }
        let content = Set(said.filter { $0.count >= 3 })
        transcriptWords = said.count
        replyWords = written.count
        contentKept = content.isEmpty ? 1 : Double(content.intersection(written).count) / Double(content.count)
        added = said.isEmpty ? 0 : Double(beyond) / Double(said.count)
        let spoken = Set(said)
        unspokenLines = reply.split(separator: "\n").filter { line in
            let words = Self.words(String(line))
            return !words.isEmpty && spoken.isDisjoint(with: words)
        }.count
    }

    // Measured on 19-Nov-26 with scripts/dev cleanup-reload over 90 replies of the three catalogue models: a sound Tidy
    // reply kept 0.67 or more and added 0.10 or less, a doubled one adds 0.30, the wrong ones after a reload kept 0.14
    // and 0.42. On 22-Nov-26 over 128 dictations in four languages, a sound Email or Message reply kept 0.8 or more and
    // one that carried out a spoken request 0.19 to 0.71. A prompt of your own rewrites freely; the shortest sound reply
    // had a fifth of the dictation's words.
    public func suits(_ prompt: Prompt) -> Bool {
        if prompt.capsReplyLength { return contentKept >= 0.55 && added <= 0.2 }
        if prompt.keepsWhatWasSaid { return contentKept >= 0.7 && unspokenLines == 0 }
        return replyWords * 8 >= transcriptWords
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
