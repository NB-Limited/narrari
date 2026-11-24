import Foundation
import Observation

public struct PromptDraft: Sendable, Equatable {
    public let id: String
    public let isNew: Bool
    public var name: String
    public var instruction: String
    public var triggers: String
}

@MainActor
@Observable
public final class PromptsPageModel: BuiltInList {
    public let builtIn = PromptStore.builtIn
    public private(set) var yours: [Prompt] = []
    public private(set) var storeError: String?
    public var draft: PromptDraft?
    public private(set) var nameError: String?
    public private(set) var instructionError: String?
    public private(set) var triggerError: String?
    public private(set) var pendingDeletion: String?
    public let file: GuardedFile

    @ObservationIgnored private let store: PromptStore

    public var unreadable: [String] { [] }

    public var editing: ListEditing? {
        draft.map { $0.isNew ? .new : .item($0.id) }
    }

    public init(store: PromptStore) {
        self.store = store
        file = GuardedFile(url: store.file.url)
        SettingsChanges.follow([PromptStore.changeKey], by: self) { $0.appear() }
    }

    public func appear() {
        storeError = nil
        if let loaded = file.read("prompts-load", store.load) { yours = loaded }
    }

    public func startFresh() {
        file.startFresh()
        appear()
    }

    public func startAdding() {
        guard !file.isUnreadable else { return }
        clearErrors()
        draft = PromptDraft(id: UUID().uuidString, isNew: true, name: "", instruction: "", triggers: "")
    }

    // Built-in prompts are read-only; a copy is yours to edit. Trigger phrases stay with the original.
    public func startDuplicating(_ id: String) {
        guard !file.isUnreadable, let prompt = builtIn.first(where: { $0.id == id }) else { return }
        clearErrors()
        draft = PromptDraft(id: UUID().uuidString, isNew: true, name: "\(prompt.name) copy", instruction: prompt.instruction, triggers: "")
    }

    public func startEditing(_ id: String) {
        guard !file.isUnreadable, let prompt = yours.first(where: { $0.id == id }) else { return }
        clearErrors()
        draft = PromptDraft(
            id: prompt.id, isNew: false, name: prompt.name, instruction: prompt.instruction,
            triggers: prompt.triggers.joined(separator: ", ")
        )
    }

    public func cancelEditing() {
        draft = nil
        clearErrors()
    }

    public func commit() {
        guard let draft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = Self.phrases(in: draft.triggers)
        nameError = name.isEmpty ? "Give the prompt a name." : nil
        instructionError = instruction.isEmpty ? "Write the instruction the clean-up follows." : nil
        triggerError = triggerProblem(triggers, excluding: draft.id)
        guard nameError == nil, instructionError == nil, triggerError == nil else { return }

        let prompt = Prompt(id: draft.id, name: name, instruction: instruction, triggers: triggers)
        let saved = edit { list in
            if let index = list.firstIndex(where: { $0.id == prompt.id }) {
                list[index] = prompt
            } else {
                list.append(prompt)
            }
        }
        if saved { self.draft = nil }
    }

    public func requestDeletion(_ id: String) {
        pendingDeletion = id
    }

    public func cancelDeletion() {
        pendingDeletion = nil
    }

    public func confirmDeletion() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        edit { $0.removeAll { $0.id == id } }
    }

    @discardableResult
    private func edit(_ change: (inout [Prompt]) -> Void) -> Bool {
        guard !file.isUnreadable else { return false }
        do {
            yours = try store.edit(change)
            storeError = nil
            return true
        } catch is DecodingError {
            appear()
        } catch {
            Log.failure("prompts-save", error: error)
            storeError = GuardedFile.saveError("prompts")
        }
        return false
    }

    private func triggerProblem(_ triggers: [String], excluding id: String) -> String? {
        let others = (builtIn + yours).filter { $0.id != id }
        for phrase in triggers {
            let key = TriggerMatcher.normalizedPhrase(phrase)
            guard !key.isEmpty else { return "“\(phrase)” has no words a trigger can match. Use letters or numbers." }
            if let owner = others.first(where: { $0.triggers.contains { TriggerMatcher.normalizedPhrase($0) == key } }) {
                return "“\(phrase)” is already a trigger phrase of \(owner.name). Use another phrase."
            }
        }
        return nil
    }

    private func clearErrors() {
        nameError = nil
        instructionError = nil
        triggerError = nil
    }

    private static func phrases(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(TriggerMatcher.normalizedPhrase($0)).inserted }
    }
}
