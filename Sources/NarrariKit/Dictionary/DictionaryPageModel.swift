import Foundation
import Observation

@MainActor
@Observable
public final class DictionaryPageModel {
    // One row of the page's lists is edited at a time.
    public enum Row: Sendable, Equatable {
        case replacement(Int)
        case mark(Int)
    }

    public private(set) var list = WordList()
    public private(set) var storeError: String?
    private var isListenerOnDisk = false
    public var newWord = ""
    public private(set) var wordError: String?
    public var newPhrase = ""
    public var newText = ""
    public private(set) var replacementError: String?
    public var writesSpokenMarks: Bool {
        get { settings[DictionarySettings.writesSpokenMarks] }
        set { settings[DictionarySettings.writesSpokenMarks] = newValue }
    }
    public var newMarkPhrase = ""
    public var newMark = SpokenMark.Mark.lineBreak
    public private(set) var markError: String?
    public private(set) var editing: Row?
    public var editPhrase = ""
    public var editText = ""
    public var editMark = SpokenMark.Mark.lineBreak
    public private(set) var editError: String?
    public let file: GuardedFile

    @ObservationIgnored private let store: DictionaryStore
    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private let listenerStatus: ModelStatus

    public init(store: DictionaryStore, settings: SettingsMirror, listenerStatus: ModelStatus, models: ModelStore) {
        self.store = store
        self.settings = settings
        file = GuardedFile(url: store.file.url)
        self.listenerStatus = listenerStatus
        self.models = models
        // A row open for editing is found by its place in the list, so the list stays as it was until the row closes.
        SettingsChanges.follow([DictionaryStore.changeKey], by: self) { page in
            if page.editing == nil { page.appear() }
        }
    }

    // At most one quiet line about getting ready to listen for the words; nothing once ready.
    public enum Listening: Sendable, Equatable {
        case quiet
        case firstWordDownloads
        case preparing(WorkState)
        case failed
    }

    public var listening: Listening {
        guard !list.words.isEmpty else { return isListenerOnDisk ? .quiet : .firstWordDownloads }
        return switch listenerStatus.state {
        case .preparing: .preparing(listenerStatus.state.work)
        case .failed: .failed
        case .missing, .ready: .quiet
        }
    }

    public var listeningLine: String? {
        switch listening {
        case .quiet: nil
        case .firstWordDownloads: "The first word downloads about 100 MB."
        case .preparing(let work): work.label
        case .failed: VocabularyError.notReady.problem.besideRetry
        }
    }

    public func appear() {
        storeError = nil
        if let loaded = file.read("dictionary-load", store.load) { list = loaded }
        isListenerOnDisk = models.isPresent(named: Vocabulary.modelName)
    }

    public func startFresh() {
        file.startFresh()
        appear()
    }

    // Asks the listener to read the word list again, without writing the file.
    public func retryListening() {
        SettingsChanges.post(DictionaryStore.changeKey)
    }

    public func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if list.words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            wordError = "“\(word)” is already in the list."
            return
        }
        if edit({ $0.words.append(word) }) {
            newWord = ""
            wordError = nil
        }
    }

    public func removeWord(_ word: String) {
        edit { $0.words.removeAll { $0 == word } }
    }

    public func addReplacement() {
        let replacement = Replacement(phrase: trimmed(newPhrase), text: trimmed(newText))
        if let problem = problem(with: replacement, skipping: nil) {
            replacementError = problem
            return
        }
        if edit({ $0.replacements.append(replacement) }) {
            newPhrase = ""
            newText = ""
            replacementError = nil
        }
    }

    public func addMark() {
        let mark = SpokenMark(phrase: trimmed(newMarkPhrase), mark: newMark)
        if let problem = problem(with: mark, skipping: nil) {
            markError = problem
            return
        }
        if edit({ $0.marks.append(mark) }) {
            newMarkPhrase = ""
            markError = nil
        }
    }

    public func startEditing(_ row: Row) {
        guard !file.isUnreadable else { return }
        switch row {
        case .replacement(let index):
            guard list.replacements.indices.contains(index) else { return }
            editPhrase = list.replacements[index].phrase
            editText = list.replacements[index].text
        case .mark(let index):
            guard list.marks.indices.contains(index) else { return }
            editPhrase = list.marks[index].phrase
            editMark = list.marks[index].mark
        }
        editing = row
        editError = nil
    }

    public func cancelEditing() {
        closeEditor()
        appear()
    }

    private func closeEditor() {
        editing = nil
        editError = nil
    }

    public func commitEditing() {
        switch editing {
        case .replacement(let index) where list.replacements.indices.contains(index):
            let replacement = Replacement(phrase: trimmed(editPhrase), text: trimmed(editText))
            if let problem = problem(with: replacement, skipping: index) { return editError = problem }
            if edit({ Self.replace(list.replacements[index], with: replacement, in: &$0.replacements) }) { closeEditor() }
        case .mark(let index) where list.marks.indices.contains(index):
            let mark = SpokenMark(phrase: trimmed(editPhrase), mark: editMark)
            if let problem = problem(with: mark, skipping: index) { return editError = problem }
            if edit({ Self.replace(list.marks[index], with: mark, in: &$0.marks) }) { closeEditor() }
        default:
            return
        }
    }

    public func remove(_ row: Row) {
        if editing == row { closeEditor() }
        switch row {
        case .replacement(let index) where list.replacements.indices.contains(index):
            edit { [original = list.replacements[index]] in $0.replacements.removeAll { $0 == original } }
        case .mark(let index) where list.marks.indices.contains(index):
            edit { [original = list.marks[index]] in $0.marks.removeAll { $0 == original } }
        default:
            return
        }
    }

    // The file is read again before each save, so the row is found by its value, not by where the page saw it.
    private static func replace<Item: Equatable>(_ original: Item, with item: Item, in items: inout [Item]) {
        if let at = items.firstIndex(of: original) {
            items[at] = item
        } else {
            items.append(item)
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func problem(with replacement: Replacement, skipping index: Int?) -> String? {
        guard !replacement.phrase.isEmpty else { return "Enter the phrase you say." }
        guard !replacement.text.isEmpty else { return "Enter the text that replaces “\(replacement.phrase)”." }
        let isTaken = Self.isTaken(replacement.phrase, in: list.replacements.map(\.phrase), skipping: index)
        return isTaken ? "“\(replacement.phrase)” already has a replacement. Edit that one instead." : nil
    }

    private func problem(with mark: SpokenMark, skipping index: Int?) -> String? {
        guard !mark.phrase.isEmpty else { return "Enter the phrase you say." }
        let isTaken = Self.isTaken(mark.phrase, in: list.marks.map(\.phrase), skipping: index)
        return isTaken ? "“\(mark.phrase)” already writes a mark. Edit that one instead." : nil
    }

    private static func isTaken(_ phrase: String, in phrases: [String], skipping index: Int?) -> Bool {
        let key = Replacements.normalizedPhrase(phrase)
        return phrases.indices.contains { $0 != index && Replacements.normalizedPhrase(phrases[$0]) == key }
    }

    @discardableResult
    private func edit(_ change: (inout WordList) -> Void) -> Bool {
        guard !file.isUnreadable else { return false }
        do {
            list = try store.edit(change)
            isListenerOnDisk = models.isPresent(named: Vocabulary.modelName)
            storeError = nil
            return true
        } catch is DecodingError {
            appear()
        } catch {
            Log.failure("dictionary-save", error: error)
            storeError = GuardedFile.saveError("dictionary")
        }
        return false
    }
}
