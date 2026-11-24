import Foundation
import Observation

@MainActor
@Observable
public final class SpeechPageModel {
    public let models: SpeechModelControl
    public let microphones: Microphones
    public let key: StoredKey
    public let catalogue: [CatalogueModel]
    public private(set) var pendingDeletion: String?
    public private(set) var changeError: String?
    public private(set) var isEditingService = false
    public var side = ModelSide.thisMac

    // While the service editor is open, its fields show what the user typed, whatever else changes the settings.
    public var remoteAddress: String {
        get { service?.address ?? settings[SpeechSettings.remoteAddress] }
        set {
            service?.address = newValue
            if ServiceAddress.isStorable(newValue) { settings[SpeechSettings.remoteAddress] = newValue }
        }
    }
    public var remoteModel: String {
        get { service?.model ?? settings[SpeechSettings.remoteModel] }
        set {
            service?.model = newValue
            settings[SpeechSettings.remoteModel] = newValue
        }
    }
    public var remoteLanguage: String {
        get { service?.language ?? settings[SpeechSettings.remoteLanguage] }
        set {
            service?.language = newValue
            settings[SpeechSettings.remoteLanguage] = newValue
        }
    }
    public var microphoneUID: String {
        get { microphones.chosenID }
        set { microphones.choose(newValue) }
    }
    public var prefersBuiltInOverBluetooth: Bool {
        get { settings[DictationSettings.prefersBuiltInOverBluetooth] }
        set {
            settings[DictationSettings.prefersBuiltInOverBluetooth] = newValue
            microphones.refresh()
        }
    }

    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let isTranscribing: @MainActor () -> Bool
    private var usesRemote: Bool {
        get { settings[SpeechSettings.usesRemote] }
        set { settings[SpeechSettings.usesRemote] = newValue }
    }
    private var savedService: ServiceFields?
    private var service: ServiceFields?
    private var triedDone = false

    private struct ServiceFields {
        var address: String
        var model: String
        var language: String
    }

    public static let busyReason = "Changing models is off while transcribing."
    public static let needsModel = "Dictation needs a speech model. Download one above."

    public init(
        models: SpeechModelControl,
        microphones: Microphones,
        settings: SettingsMirror,
        keychain: any KeyStoring,
        catalogue: [CatalogueModel] = ModelCatalogue.speech,
        isTranscribing: @escaping @MainActor () -> Bool = { false }
    ) {
        self.models = models
        self.microphones = microphones
        self.settings = settings
        self.catalogue = catalogue
        self.isTranscribing = isTranscribing
        key = StoredKey(account: SpeechSettings.remoteKeyAccount, keychain: keychain)
    }

    // Only the chosen model has a state; the others are on disk or still to download.
    public func row(for model: CatalogueModel) -> ModelRow {
        let speech = ParakeetModel(rawValue: model.id)
        let bytes = speech.flatMap { models.bytesOnDisk[$0] } ?? 0
        let isChosen = speech == models.chosen
        return ModelRow(state: isChosen ? models.state : .missing, isChosen: isChosen, bytesOnDisk: bytes)
    }

    public var groups: [(group: ModelGroup, models: [CatalogueModel])] { ModelGroup.split(catalogue, row: row(for:)) }

    public var readings: [String: [MetricReading]] { MetricScale.readings(for: catalogue) }

    // Modes choose the outside service, so the model in use is always one on this Mac.
    public var sideInUse: ModelSide? {
        catalogue.contains { row(for: $0).mark == .chosen } ? .thisMac : nil
    }

    // The model is never swapped or torn down under a running transcription.
    public var isChangeBlocked: Bool { isTranscribing() }

    public var showsNeedsModel: Bool {
        catalogue.allSatisfy { row(for: $0).status == .notDownloaded }
    }

    // Download and Try again make the model the one in use, like choosing it, downloading it first.
    public func perform(_ action: ModelRow.Action, on model: CatalogueModel) {
        if action == .cancel {
            changeError = nil
            models.cancel()
            return
        }
        choose(model)
    }

    public func choose(_ model: CatalogueModel) {
        changeError = nil
        guard let speech = ParakeetModel(rawValue: model.id) else { return }
        guard !isTranscribing() else {
            changeError = Self.busyReason
            return
        }
        models.use(speech)
    }

    public func requestDeletion(of model: CatalogueModel) {
        changeError = nil
        guard !isTranscribing() else {
            changeError = Self.busyReason
            return
        }
        pendingDeletion = model.id
    }

    public func deletionMessage(for model: CatalogueModel) -> String {
        let bytes = ParakeetModel(rawValue: model.id).flatMap { models.bytesOnDisk[$0] } ?? 0
        return row(for: model).isInUse
            ? "Delete \(model.name) from this Mac? Dictation stops until you choose another model."
            : "Delete \(model.name) from this Mac? This frees \(MetricText.bytes(bytes))."
    }

    public func cancelDeletion() {
        pendingDeletion = nil
    }

    public func confirmDeletion() async {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        guard !isTranscribing() else {
            changeError = Self.busyReason
            return
        }
        guard let model = ParakeetModel(rawValue: id) else { return }
        do {
            try await models.delete(model)
        } catch {
            Log.failure("speech-model-delete", error: error)
            changeError = "The model files could not be deleted. Try again, or remove them in Finder."
        }
    }

    // Modes choose the service, so it is no choice in this list: set up is as far as this page goes.
    public var serviceRow: OutsideServiceRow {
        let status: OutsideServiceRow.Status = if !usesRemote {
            .notSetUp
        } else if let problem = addressError ?? modelError ?? languageError {
            .problem(problem)
        } else {
            .ready
        }
        return OutsideServiceRow(status: status, job: .speech, address: remoteAddress, model: remoteModel, isEditing: isEditingService)
    }

    public func beginServiceSetup() {
        savedService = ServiceFields(address: remoteAddress, model: remoteModel, language: remoteLanguage)
        service = savedService
        triedDone = false
        isEditingService = true
        key.refresh()
    }

    // Done keeps the fields only once the service can be used.
    public func finishServiceSetup() {
        triedDone = true
        guard addressError == nil, modelError == nil, languageError == nil else { return }
        usesRemote = true
        closeServiceSetup(keeping: service)
    }

    public func cancelServiceSetup() {
        closeServiceSetup(keeping: savedService)
    }

    private func closeServiceSetup(keeping fields: ServiceFields?) {
        service = nil
        if let fields {
            remoteAddress = fields.address
            remoteModel = fields.model
            remoteLanguage = fields.language
        }
        savedService = nil
        triedDone = false
        isEditingService = false
    }

    public var addressError: String? {
        guard usesRemote || triedDone || !remoteAddress.isEmpty else { return nil }
        return ServiceAddress.problem(with: remoteAddress)
    }

    public var modelError: String? {
        guard usesRemote || triedDone, remoteModel.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "Enter the model name the service expects."
    }

    public var languageError: String? {
        let code = remoteLanguage.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, code.range(of: "^[a-z]{2,3}$", options: .regularExpression) == nil else { return nil }
        return "Use a two-letter language code such as en or de, or leave it empty to detect."
    }

    public var microphoneOptions: [(value: String, title: String)] {
        microphones.options.map { ($0.id, $0.title) }
    }

    // The line under the microphone row.
    public var microphoneDetail: String? {
        if microphones.isChosenMissing { return "Not connected. Using the system default." }
        guard microphoneUID.isEmpty, let name = microphones.automatic?.name else { return nil }
        return "Using \(name)."
    }

    public var isMicrophoneChosen: Bool {
        !microphoneUID.isEmpty && !microphones.isChosenMissing
    }

    public func appear() {
        side = sideInUse ?? .thisMac
        microphones.start()
        models.refreshSize()
        key.refresh()
    }

    public func disappear() {
        microphones.stop()
    }
}
