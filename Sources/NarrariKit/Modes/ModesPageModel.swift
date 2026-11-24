import Foundation
import Observation

public struct ModeDraft: Sendable, Equatable {
    public let id: String
    public let isNew: Bool
    public var name: String
    public var promptID: String
    public var isCleanupOn: Bool
    public var speech: Mode.Speech
}

@MainActor
@Observable
public final class ModesPageModel {
    public private(set) var book = ModeBook()
    public private(set) var prompts: [Prompt] = PromptStore.builtIn
    public private(set) var storeError: String?
    public var draft: ModeDraft?
    public private(set) var nameError: String?
    public private(set) var pendingDeletion: String?
    public let file: GuardedFile

    @ObservationIgnored private let store: ModeStore
    @ObservationIgnored private let promptStore: PromptStore
    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored public let apps: AppDirectory

    public static let outsideReason = "Set it up on the Speech page first."
    public static let globalDefaultReason = "The default for every app can't be deleted."

    public init(
        store: ModeStore, prompts: PromptStore, settings: SettingsMirror, apps: AppDirectory
    ) {
        self.store = store
        file = GuardedFile(url: store.file.url)
        self.apps = apps
        promptStore = prompts
        self.settings = settings
        SettingsChanges.follow([ModeStore.changeKey, PromptStore.changeKey], by: self) { $0.appear() }
    }

    public var isOutsideReady: Bool { RemoteTranscriber.isSetUp(settings: settings.store) }

    public func appear() {
        storeError = nil
        if let loaded = file.read("modes-load", store.load) { book = loaded }
        do {
            prompts = try promptStore.all()
        } catch {
            Log.failure("prompts-load", error: error)
            prompts = PromptStore.builtIn
        }
    }

    public func promptName(_ id: String) -> String {
        (prompts.first { $0.id == id } ?? .tidy).name
    }

    public func summary(of mode: Mode) -> String {
        let cleanup = mode.isCleanupOn ? promptName(mode.promptID) : "Clean-up off"
        let speech = switch mode.speech {
        case .local: "speech on this Mac"
        case .outside: isOutsideReady ? "outside speech service" : "outside service not set up, speech on this Mac"
        }
        return "\(cleanup), \(speech)"
    }

    public var globalDefaultID: String {
        get { book.globalDefaultID }
        set { edit { try $0.setGlobalDefault(newValue) } }
    }

    public func startAdding() {
        guard !file.isUnreadable else { return }
        nameError = nil
        draft = ModeDraft(id: UUID().uuidString, isNew: true, name: "", promptID: Prompt.tidy.id, isCleanupOn: true, speech: .local)
    }

    public func startEditing(_ id: String) {
        guard !file.isUnreadable, let mode = book.mode(id: id) else { return }
        nameError = nil
        draft = ModeDraft(
            id: mode.id, isNew: false, name: mode.name, promptID: mode.promptID, isCleanupOn: mode.isCleanupOn, speech: mode.speech
        )
    }

    public func cancelEditing() {
        draft = nil
        nameError = nil
    }

    public func commit() {
        guard let draft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            nameError = "Give the mode a name."
        } else if book.modes.contains(where: { $0.id != draft.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            nameError = "Another mode is called \(name). Use another name."
        } else {
            nameError = nil
        }
        guard nameError == nil else { return }
        let mode = Mode(id: draft.id, name: name, promptID: draft.promptID, isCleanupOn: draft.isCleanupOn, speech: draft.speech)
        if edit({ draft.isNew ? try $0.add(mode) : try $0.update(mode) }) { self.draft = nil }
    }

    public func canDelete(_ id: String) -> Bool { id != book.globalDefaultID }

    public func requestDeletion(_ id: String) {
        guard canDelete(id) else { return }
        pendingDeletion = id
    }

    public func cancelDeletion() {
        pendingDeletion = nil
    }

    public func confirmDeletion() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        edit { try $0.delete(id) }
    }

    public func appsUsing(_ id: String) -> Int {
        book.apps.values.filter { $0.modeIDs.contains(id) }.count
    }

    // Apps sorted by name; the name and icon come from the app helper in the view.
    public var appIDs: [String] {
        book.apps.keys.sorted { apps.name(for: $0).localizedStandardCompare(apps.name(for: $1)) == .orderedAscending }
    }

    public func appChoices() async -> [AppDirectory.Listing] {
        await apps.installedAndRunning().filter { book.apps[$0.bundleIdentifier] == nil }
    }

    public func addApp(_ bundleIdentifier: String) {
        let id = book.globalDefaultID
        edit { try $0.setModes(for: bundleIdentifier, ids: [id], defaultID: id) }
    }

    public func removeApp(_ bundleIdentifier: String) {
        edit { try $0.setModes(for: bundleIdentifier, ids: [], defaultID: "") }
    }

    public func addMode(_ id: String, to app: String) {
        guard let entry = book.apps[app], !entry.modeIDs.contains(id) else { return }
        edit { try $0.setModes(for: app, ids: entry.modeIDs + [id], defaultID: entry.defaultID) }
    }

    public func removeMode(_ id: String, from app: String) {
        guard let entry = book.apps[app], entry.modeIDs.count > 1 else { return }
        let ids = entry.modeIDs.filter { $0 != id }
        edit { try $0.setModes(for: app, ids: ids, defaultID: entry.defaultID == id ? ids[0] : entry.defaultID) }
    }

    public func moveMode(_ id: String, in app: String, to target: Int) {
        guard let entry = book.apps[app], let index = entry.modeIDs.firstIndex(of: id) else { return }
        var ids = entry.modeIDs
        ids.remove(at: index)
        ids.insert(id, at: min(max(target, 0), ids.count))
        guard ids != entry.modeIDs else { return }
        edit { try $0.setModes(for: app, ids: ids, defaultID: entry.defaultID) }
    }

    public func setDefault(_ id: String, for app: String) {
        guard let entry = book.apps[app] else { return }
        edit { try $0.setModes(for: app, ids: entry.modeIDs, defaultID: id) }
    }

    public func startFresh() {
        file.startFresh()
        appear()
    }

    @discardableResult
    private func edit(_ change: (inout ModeBook) throws -> Void) -> Bool {
        guard !file.isUnreadable else { return false }
        do {
            book = try store.edit(change)
            storeError = nil
            return true
        } catch let error as ModeError {
            Log.failure("modes-edit", error: error)
            storeError = "That change could not be made to your modes. Open this page again and retry."
        } catch is DecodingError {
            appear()
        } catch {
            Log.failure("modes-save", error: error)
            storeError = GuardedFile.saveError("modes")
        }
        return false
    }
}
