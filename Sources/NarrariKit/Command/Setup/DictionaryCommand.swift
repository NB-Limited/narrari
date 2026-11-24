import Foundation

public enum DictionaryCommand: Sendable, Equatable {
    case list(asJSON: Bool)
    case add(String)
    case remove(String)
    case replace(String, with: String)
    case unreplace(String)
    case mark(String, as: String)
    case unmark(String)

    static let mistake = "dictionary takes list [--json], add <word>, remove <word>, replace <phrase> <text>, unreplace <phrase>, "
        + "mark <phrase> <mark> or unmark <phrase>."

    init?(_ arguments: [String]) {
        let rest = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        switch (arguments.first, arguments.count) {
        case ("list", 1): self = .list(asJSON: false)
        case ("list", 2) where arguments[1] == "--json": self = .list(asJSON: true)
        case ("add", 2...) where !rest.isEmpty: self = .add(rest)
        case ("remove", 2...) where !rest.isEmpty: self = .remove(rest)
        case ("replace", 3): self = .replace(arguments[1], with: arguments[2])
        case ("unreplace", 2...) where !rest.isEmpty: self = .unreplace(rest)
        case ("mark", 3): self = .mark(arguments[1], as: arguments[2])
        case ("unmark", 2...) where !rest.isEmpty: self = .unmark(rest)
        default: return nil
        }
    }

    @MainActor
    func run(in context: Command.Context) -> Command.Reply {
        let page = DictionaryPageModel(
            store: context.dictionary, settings: SettingsMirror(context.settings), listenerStatus: ModelStatus(), models: context.models
        )
        page.appear()
        if case .list(let asJSON) = self { return .ok(asJSON ? SetupInput.json(page.list) : Self.rows(page.list)) }
        guard !page.file.isUnreadable else {
            return .failed("\(page.file.name) can't be read, so nothing was changed. Fix it, or start it fresh in Settings, Dictionary.\n")
        }
        let reply = change(page)
        if reply.status == 0 { context.announce(DictionaryStore.changeKey) }
        return reply
    }

    @MainActor
    private func change(_ page: DictionaryPageModel) -> Command.Reply {
        switch self {
        case .list: return .ok("")
        case .add(let word):
            page.newWord = word
            page.addWord()
            return .refused(page.wordError ?? page.storeError, else: "Added \(word).\n")
        case .remove(let word):
            guard let found = page.list.words.first(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else {
                return .failed("\(word) is not in the dictionary.\n")
            }
            page.removeWord(found)
            return .refused(page.storeError, else: "Removed \(found).\n")
        case .replace(let phrase, let text): return Self.replace(phrase, with: text, on: page)
        case .unreplace(let phrase):
            guard let index = Self.index(of: phrase, in: page.list.replacements.map(\.phrase)) else {
                return .failed("\(phrase) has no replacement.\n")
            }
            page.remove(.replacement(index))
            return .refused(page.storeError, else: "\(phrase) is no longer replaced.\n")
        case .mark(let phrase, let name): return Self.mark(phrase, as: name, on: page)
        case .unmark(let phrase):
            guard let index = Self.index(of: phrase, in: page.list.marks.map(\.phrase)) else { return .failed("\(phrase) writes no mark.\n") }
            page.remove(.mark(index))
            return .refused(page.storeError, else: "\(phrase) no longer writes a mark.\n")
        }
    }

    // A phrase that has a replacement already gets the new text, as editing its row would.
    @MainActor
    private static func replace(_ phrase: String, with text: String, on page: DictionaryPageModel) -> Command.Reply {
        if let index = index(of: phrase, in: page.list.replacements.map(\.phrase)) {
            page.startEditing(.replacement(index))
            page.editPhrase = phrase
            page.editText = text
            page.commitEditing()
            return .refused(page.editError ?? page.storeError, else: "\(phrase) is now replaced with \(text).\n")
        }
        page.newPhrase = phrase
        page.newText = text
        page.addReplacement()
        return .refused(page.replacementError ?? page.storeError, else: "\(phrase) is now replaced with \(text).\n")
    }

    @MainActor
    private static func mark(_ phrase: String, as name: String, on page: DictionaryPageModel) -> Command.Reply {
        guard let mark = SpokenMark.Mark(rawValue: name) else {
            return .failed("\(name) is not a mark. Use one of \(SpokenMark.Mark.allCases.map(\.rawValue).joined(separator: ", ")).\n")
        }
        if let index = index(of: phrase, in: page.list.marks.map(\.phrase)) {
            page.startEditing(.mark(index))
            page.editPhrase = phrase
            page.editMark = mark
            page.commitEditing()
            return .refused(page.editError ?? page.storeError, else: "\(phrase) now writes \(name).\n")
        }
        page.newMarkPhrase = phrase
        page.newMark = mark
        page.addMark()
        return .refused(page.markError ?? page.storeError, else: "\(phrase) now writes \(name).\n")
    }

    private static func index(of phrase: String, in phrases: [String]) -> Int? {
        let key = Replacements.normalizedPhrase(phrase)
        return phrases.firstIndex { Replacements.normalizedPhrase($0) == key }
    }

    private static func rows(_ list: WordList) -> String {
        let words = list.words.isEmpty ? "No words.\n" : list.words.map { $0 + "\n" }.joined()
        let replacements = list.replacements.isEmpty
            ? "No replacements.\n" : RecordKind.table(["PHRASE", "TEXT"], list.replacements.map { [$0.phrase, $0.text] })
        let marks = list.marks.isEmpty ? "No spoken marks.\n" : RecordKind.table(["PHRASE", "MARK"], list.marks.map { [$0.phrase, $0.mark.rawValue] })
        return "Words\n\(words)\nReplacements\n\(replacements)\nSpoken marks, written while dictionary.writesSpokenMarks is true\n\(marks)"
    }
}
