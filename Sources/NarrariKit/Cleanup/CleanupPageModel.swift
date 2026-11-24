import Foundation
import Observation

@MainActor
@Observable
public final class CleanupPageModel {
    private static let chatTimeLimits: [Double] = [4, 8, 12, 20]

    public let engines: CleanupEngineSlot
    public let key: StoredKey
    public private(set) var bytesOnDisk: Int64 = 0
    public private(set) var pendingDeletion: String?
    public private(set) var deletionError: String?
    public private(set) var otherModels: [CachedModel] = []
    public private(set) var isEditingService = false
    public var side = ModelSide.thisMac

    public var isEnabled: Bool {
        get { settings[CleanupSettings.isEnabled] }
        set { settings[CleanupSettings.isEnabled] = newValue }
    }
    public var usesOutsideService: Bool {
        get { settings[CleanupSettings.engine] == .chat }
        set { settings[CleanupSettings.engine] = newValue ? .chat : .local }
    }
    // While the service editor is open, its fields show what the user typed, whatever else changes the settings.
    public var chatAddress: String {
        get { service?.address ?? settings[CleanupSettings.chatAddress] }
        set {
            service?.address = newValue
            if ServiceAddress.isStorable(newValue) { settings[CleanupSettings.chatAddress] = newValue }
        }
    }
    public var chatModel: String {
        get { service?.model ?? settings[CleanupSettings.chatModel] }
        set {
            service?.model = newValue
            settings[CleanupSettings.chatModel] = newValue
        }
    }
    public var chatTimeLimit: Double {
        get { service?.timeLimit ?? settings[CleanupSettings.chatTimeLimit] }
        set {
            service?.timeLimit = newValue
            settings[CleanupSettings.chatTimeLimit] = newValue
        }
    }
    public var usesTriggers: Bool {
        get { settings[CleanupSettings.usesTriggers] }
        set { settings[CleanupSettings.usesTriggers] = newValue }
    }
    public var skippedLanguages: [String] { settings[CleanupSettings.skippedLanguages] }

    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let catalogue: [CatalogueModel]
    private var savedService: ServiceFields?
    private var service: ServiceFields?
    private var triedDone = false

    private struct ServiceFields {
        var address: String
        var model: String
        var timeLimit: Double
    }

    public init(
        engines: CleanupEngineSlot,
        settings: SettingsMirror,
        keychain: any KeyStoring,
        catalogue: [CatalogueModel] = ModelCatalogue.cleanup
    ) {
        self.engines = engines
        self.settings = settings
        self.catalogue = catalogue
        key = StoredKey(account: CleanupSettings.chatKeyAccount, keychain: keychain)
    }

    public var languagesToSkip: [SpokenLanguage] {
        SpokenLanguage.detectable.filter { !skippedLanguages.contains($0.id) }
    }

    public func skip(_ language: String) {
        guard !skippedLanguages.contains(language) else { return }
        settings[CleanupSettings.skippedLanguages] = skippedLanguages + [language]
    }

    public func stopSkipping(_ language: String) {
        settings[CleanupSettings.skippedLanguages] = skippedLanguages.filter { $0 != language }
    }

    private var localModel: ModelReference { ModelReference(settings[CleanupSettings.localModel]) }

    // The catalogue first, then models downloaded earlier that it does not list.
    public var models: [CatalogueModel] {
        let listed = Set(catalogue.map { ModelReference($0.id).id })
        return catalogue + otherModels.filter { !listed.contains($0.id) }.map { other in
            CatalogueModel(id: other.id, name: other.displayName, metrics: ModelMetrics(diskBytes: other.bytesOnDisk))
        }
    }

    public var groups: [(group: ModelGroup, models: [CatalogueModel])] { ModelGroup.split(models, row: row(for:)) }

    // Files the catalogue no longer lists are not offered, so they stay out of the comparison.
    public var readings: [String: [MetricReading]] { MetricScale.readings(for: catalogue) }

    public var sideInUse: ModelSide? {
        if usesOutsideService { return .outside }
        return models.contains { row(for: $0).mark == .chosen } ? .thisMac : nil
    }

    // A model the catalogue does not list has no pinned revision, so it is offered for deletion only.
    public func row(for model: CatalogueModel) -> ModelRow {
        let reference = ModelReference(model.id)
        if reference.id == localModel.id {
            return ModelRow(state: engines.localStatus.state, isChosen: !usesOutsideService, bytesOnDisk: bytesOnDisk)
        }
        let bytes = otherModels.first { $0.id == reference.id }?.bytesOnDisk ?? 0
        return ModelRow(state: .missing, isChosen: false, bytesOnDisk: bytes, canUse: catalogue.contains(model))
    }

    // Download and Try again make the model the one in use, like choosing it.
    public func perform(_ action: ModelRow.Action, on model: CatalogueModel) {
        if action == .cancel {
            deletionError = nil
            Task {
                await engines.cancelLocal()
                refreshSize()
            }
            return
        }
        choose(model)
    }

    // Choosing a model that is not loaded loads it, which downloads it first when it is not on this Mac.
    public func choose(_ model: CatalogueModel) {
        deletionError = nil
        guard catalogue.contains(model) else { return }
        let isLoaded = ModelReference(model.id).id == localModel.id
        if !isLoaded {
            settings[CleanupSettings.localModel] = model.id
            // The sizes are kept per the model in use and the others, so they are read again for the new split.
            refreshSize()
        }
        if usesOutsideService {
            usesOutsideService = false
        } else if isLoaded {
            engines.loadLocal()
        }
    }

    public func requestDeletion(of model: CatalogueModel) {
        deletionError = nil
        pendingDeletion = model.id
    }

    public func deletionMessage(for model: CatalogueModel) -> String {
        let row = row(for: model)
        if row.isInUse { return "Delete \(model.name) from this Mac? Clean-up is skipped until you choose another model." }
        let bytes = ModelReference(model.id).id == localModel.id
            ? bytesOnDisk
            : otherModels.first { $0.id == ModelReference(model.id).id }?.bytesOnDisk ?? 0
        return "Delete \(model.name) from this Mac? This frees \(MetricText.bytes(bytes))."
    }

    public func cancelDeletion() {
        pendingDeletion = nil
    }

    public func confirmDeletion() async {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        let reference = ModelReference(id)
        do {
            if reference.id == localModel.id {
                try await engines.deleteLocal()
            } else {
                try await engines.deleteOther(reference.id)
            }
        } catch {
            Log.failure("cleanup-model-delete", error: error)
            deletionError = "The model files could not be deleted. Try again, or remove them in Finder."
        }
        refreshSize()
    }

    public var isServiceSetUp: Bool {
        ServiceAddress.problem(with: chatAddress) == nil && !chatModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var serviceRow: OutsideServiceRow {
        let status: OutsideServiceRow.Status = if usesOutsideService, let problem = addressError ?? modelError {
            .problem(problem)
        } else if usesOutsideService {
            .inUse
        } else if isServiceSetUp {
            .ready
        } else {
            .notSetUp
        }
        return OutsideServiceRow(status: status, job: .cleanup, address: chatAddress, model: chatModel, isEditing: isEditingService)
    }

    public func chooseService() {
        guard isServiceSetUp else { return beginServiceSetup() }
        usesOutsideService = true
    }

    public func beginServiceSetup() {
        savedService = ServiceFields(address: chatAddress, model: chatModel, timeLimit: chatTimeLimit)
        service = savedService
        triedDone = false
        isEditingService = true
        key.refresh()
    }

    // Done keeps the fields only once the service can be used; it never switches clean-up to it.
    public func finishServiceSetup() {
        triedDone = true
        guard addressError == nil, modelError == nil else { return }
        closeServiceSetup(keeping: service)
    }

    public func cancelServiceSetup() {
        closeServiceSetup(keeping: savedService)
    }

    private func closeServiceSetup(keeping fields: ServiceFields?) {
        service = nil
        if let fields {
            chatAddress = fields.address
            chatModel = fields.model
            chatTimeLimit = fields.timeLimit
        }
        savedService = nil
        triedDone = false
        isEditingService = false
    }

    public var addressError: String? {
        guard usesOutsideService || triedDone || !chatAddress.isEmpty else { return nil }
        return ServiceAddress.problem(with: chatAddress)
    }

    public var modelError: String? {
        guard usesOutsideService || triedDone, chatModel.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "Enter the model name the service expects."
    }

    public var chatTimeLimitOptions: [Double] {
        Self.chatTimeLimits.including(chatTimeLimit, inOrder: <)
    }

    // Opens on the side that holds the model in use.
    public func appear() {
        refreshSize()
        side = sideInUse ?? .thisMac
        key.refresh()
    }

    public func refreshSize() {
        do {
            bytesOnDisk = try engines.localBytesOnDisk()
        } catch {
            Log.failure("cleanup-model-size", error: error)
        }
        otherModels = engines.otherLocalModels()
    }
}
