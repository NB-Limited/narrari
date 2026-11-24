import Foundation
import Observation

public struct TemplateDraft: Sendable, Equatable {
    // Nil until a new template is saved.
    public let id: String?
    public var name: String
    public var text: String
}

// The Summaries page: the summary templates, built like the prompts, and how summaries are written. The files stay the
// truth, so a template written by hand shows on the next read.
@MainActor
@Observable
public final class SummariesPageModel: BuiltInList {
    // The templates folder announces nothing itself; the narrari command posts this after it writes there.
    public nonisolated static let changeKey = "templates"

    public private(set) var builtIn: [SummaryTemplate] = []
    public private(set) var yours: [SummaryTemplate] = []
    public private(set) var unreadable: [String] = []
    public var defaultID: String { settings[MeetingsSettings.summaryTemplate] }
    public var draft: TemplateDraft?
    public private(set) var nameError: String?
    public private(set) var textError: String?
    public private(set) var pendingDeletion: String?
    public private(set) var error: String?
    // Empty stands for the clean-up model, so summaries follow clean-up when its model changes.
    public var summaryModel: String {
        get { settings[MeetingsSettings.summaryModel] }
        set { settings[MeetingsSettings.summaryModel] = newValue }
    }
    // The clean-up model's row carries the empty value; the chat service is listed while chosen, even once removed.
    public private(set) var summaryOptions: [SummaryModels.Choice] = []
    public private(set) var isOutsideSetUp = false

    @ObservationIgnored private let folder: SummaryTemplateFolder
    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let summaryModels: SummaryModels

    public init(folder: SummaryTemplateFolder, settings: SettingsMirror, summaryModels: SummaryModels) {
        self.folder = folder
        self.settings = settings
        self.summaryModels = summaryModels
        SettingsChanges.follow([SummariesPageModel.changeKey], by: self) { $0.readTemplates() }
        let offered = [CleanupSettings.localModel, CleanupSettings.chatAddress, CleanupSettings.chatModel].map(\.key)
        SettingsChanges.follow(Set(offered), by: self) { $0.readSummaryModels() }
    }

    public var editing: ListEditing? {
        draft.map { $0.id.map(ListEditing.item) ?? .new }
    }

    public func appear() {
        readSummaryModels()
        readTemplates()
    }

    func readTemplates() {
        do {
            let listing = try folder.listing()
            builtIn = listing.templates.filter { SummaryTemplateFolder.builtInIDs.contains($0.id) }
            yours = listing.templates.filter { !SummaryTemplateFolder.builtInIDs.contains($0.id) }
            unreadable = listing.unreadable
            error = nil
        } catch {
            Log.failure("templates-read", error: error)
            self.error = "The templates folder could not be read. Check that it still exists and can be opened."
        }
    }

    private func readSummaryModels() {
        isOutsideSetUp = summaryModels.isOutsideSetUp
        let cleanup = summaryModels.cleanupModel
        var options = summaryModels.choices().map { SummaryModels.Choice(id: $0.id == cleanup ? "" : $0.id, name: $0.name) }
        if summaryModel == SummaryModels.outside, !isOutsideSetUp {
            options.append(SummaryModels.Choice(id: SummaryModels.outside, name: SummaryModels.serviceName))
        }
        if !options.contains(where: { $0.id == summaryModel }) { summaryModel = "" }
        summaryOptions = options
    }

    public func makeDefault(_ id: String) {
        settings[MeetingsSettings.summaryTemplate] = id
    }

    public func startAdding() {
        clearErrors()
        draft = TemplateDraft(id: nil, name: "", text: "")
    }

    // Built-in templates are read-only, like built-in prompts; a copy is yours to edit.
    public func startDuplicating(_ id: String) {
        guard let template = builtIn.first(where: { $0.id == id }) else { return }
        clearErrors()
        draft = TemplateDraft(id: nil, name: "\(template.name) copy", text: template.text)
    }

    public func startEditing(_ id: String) {
        guard let template = yours.first(where: { $0.id == id }) else { return }
        clearErrors()
        draft = TemplateDraft(id: template.id, name: template.name, text: template.text)
    }

    public func cancelEditing() {
        draft = nil
        clearErrors()
    }

    public func commit() {
        guard let draft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        nameError = name.isEmpty ? "Give the template a name." : nil
        textError = (try? SummaryTemplate(id: "draft", markdown: SummaryTemplate.markdown(name: name, text: text))) == nil
            ? "Start each heading with #, and write under it what goes there." : nil
        guard nameError == nil, textError == nil else { return }
        do {
            try folder.save(draft.id ?? folder.newID(for: name), name: name, text: text)
            self.draft = nil
            appear()
        } catch {
            Log.failure("template-save", error: error)
            self.error = "The template could not be saved. Check that the templates folder can be opened, then try again."
        }
    }

    public func requestDeletion(_ id: String) {
        pendingDeletion = id
    }

    public func cancelDeletion() {
        pendingDeletion = nil
    }

    // Deleting the default hands it back to the shipped default.
    public func confirmDeletion() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        do {
            try folder.delete(id)
        } catch {
            Log.failure("template-delete", error: error)
            self.error = "The template could not be deleted. Try again."
        }
        if id == defaultID { makeDefault(MeetingsSettings.summaryTemplate.defaultValue) }
        appear()
    }

    private func clearErrors() {
        nameError = nil
        textError = nil
    }
}
