import Foundation

public enum CleanupSwitch: Sendable, Equatable {
    case on
    case off(CleanupResult.Reason)
}

public struct TextPipeline: Sendable {
    public struct Result: Sendable, Equatable {
        public let rawText: String
        public let prompt: Prompt
        public let isTriggered: Bool
        public let cleanup: CleanupResult
        public let finalText: String
    }

    private let cleanup: CleanupService
    private let prompts: PromptStore
    private let dictionary: DictionaryStore
    private let settings: SettingsStore

    public init(
        cleanup: CleanupService,
        prompts: PromptStore,
        dictionary: DictionaryStore,
        settings: SettingsStore
    ) {
        self.cleanup = cleanup
        self.prompts = prompts
        self.dictionary = dictionary
        self.settings = settings
    }

    public func run(_ transcript: String, prompt defaultPrompt: Prompt, cleanup choice: CleanupSwitch) async -> Result {
        let match = triggerMatch(transcript)
        return await finish(transcript, match: match, prompt: match.prompt ?? defaultPrompt, cleanup: choice)
    }

    // A past dictation's heard text again, with the prompt chosen or, for nil, as spoken. A spoken trigger phrase is
    // still left out, but the prompt chosen wins over the one it names.
    public func run(heard transcript: String, prompt: Prompt?) async -> Result {
        await finish(transcript, match: triggerMatch(transcript), prompt: prompt ?? .tidy, cleanup: prompt == nil ? nil : .on)
    }

    // A nil choice keeps the text as spoken without a reason, as a file is.
    private func finish(_ transcript: String, match: TriggerMatcher.Match, prompt: Prompt, cleanup choice: CleanupSwitch?) async -> Result {
        let list = wordList()
        let marked = settings.value(DictionarySettings.writesSpokenMarks)
            ? SpokenMarks.apply(list.marks, to: match.text)
            : SpokenMarks.Applied(text: match.text, written: 0)
        if marked.written > 0 { Log.count("spoken-marks-written", marked.written) }

        let cleaned: CleanupResult
        switch choice {
        case nil:
            cleaned = CleanupResult(text: marked.text, model: "", status: .off, reason: nil)
        case .off(let reason):
            cleaned = CleanupResult(text: marked.text, model: "", status: .off, reason: reason)
        case .on where match.text.isEmpty:
            cleaned = CleanupResult(text: "", model: "", status: .skipped, reason: .nothingToClean)
        case .on where isSkippedLanguage(match.text):
            cleaned = CleanupResult(text: marked.text, model: "", status: .off, reason: .skippedLanguage)
        case .on where marked.text.allSatisfy(\.isWhitespace):
            cleaned = CleanupResult(text: marked.text, model: "", status: .skipped, reason: .nothingToClean)
        case .on where prompt.capsReplyLength && marked.written > 0 && marked.text.contains("\n"):
            cleaned = await cleanParagraphs(marked.text, with: prompt, spellings: list.words)
        case .on:
            cleaned = await cleanup.clean(marked.text, with: prompt, spellings: list.words)
        }

        return Result(
            rawText: transcript,
            prompt: prompt,
            isTriggered: match.prompt != nil,
            cleanup: cleaned,
            finalText: Replacements.apply(list.replacements, to: cleaned.text)
        )
    }

    // A transcribed file is kept as heard: no trigger words, no clean-up, only the dictionary's replacements.
    public func file(_ transcript: String) -> Result {
        Result(
            rawText: transcript,
            prompt: .tidy,
            isTriggered: false,
            cleanup: CleanupResult(text: transcript, model: "", status: .off, reason: nil),
            finalText: Replacements.apply(wordList().replacements, to: transcript)
        )
    }

    // Measured 20-Nov-26: the model drops most line breaks, so a prompt that keeps the speaker's words cleans each
    // paragraph alone, and one not cleaned leaves the dictation as heard; a prompt that rewrites gets the whole text.
    private func cleanParagraphs(_ text: String, with prompt: Prompt, spellings: [String]) async -> CleanupResult {
        var result = ""
        var model = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            let paragraph = rest.prefix { $0 != "\n" }
            let breaks = rest[paragraph.endIndex...].prefix { $0 == "\n" }
            if !paragraph.allSatisfy(\.isWhitespace) {
                let cleaned = await cleanup.clean(String(paragraph), with: prompt, spellings: spellings)
                guard cleaned.status == .cleaned else {
                    return CleanupResult(text: text, model: cleaned.model, status: cleaned.status, reason: cleaned.reason)
                }
                result += cleaned.text
                model = cleaned.model
            }
            result += breaks
            rest = rest[breaks.endIndex...]
        }
        return CleanupResult(text: result, model: model, status: .cleaned, reason: nil)
    }

    @MainActor public func holdCleanupModel() { cleanup.holdModel() }
    @MainActor public func releaseCleanupModel() { cleanup.releaseModel() }

    private func triggerMatch(_ transcript: String) -> TriggerMatcher.Match {
        settings.value(CleanupSettings.usesTriggers)
            ? TriggerMatcher.match(transcript, prompts: allPrompts())
            : TriggerMatcher.Match(prompt: nil, text: transcript)
    }

    public func prompt(id: String) -> Prompt {
        allPrompts().first { $0.id == id } ?? .tidy
    }

    private func isSkippedLanguage(_ text: String) -> Bool {
        let skipped = settings.value(CleanupSettings.skippedLanguages)
        guard !skipped.isEmpty, let language = SpokenLanguage.detect(text) else { return false }
        return skipped.contains(language)
    }

    public func allPrompts() -> [Prompt] {
        do {
            return try prompts.all()
        } catch {
            Log.failure("prompts-load-pipeline", error: error)
            return PromptStore.builtIn
        }
    }

    private func wordList() -> WordList {
        dictionary.loadOrEmpty("dictionary-load-pipeline")
    }
}
