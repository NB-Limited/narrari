import Foundation

// What the Speech and Clean-up pages share for their list of models on this Mac.
@MainActor
public protocol ModelListing: AnyObject {
    var groups: [(group: ModelGroup, models: [CatalogueModel])] { get }
    var readings: [String: [MetricReading]] { get }
    var pendingDeletion: String? { get }
    func row(for model: CatalogueModel) -> ModelRow
    func deletionMessage(for model: CatalogueModel) -> String
    func choose(_ model: CatalogueModel)
    func perform(_ action: ModelRow.Action, on model: CatalogueModel)
    func requestDeletion(of model: CatalogueModel)
    func cancelDeletion()
    func confirmDeletion() async
}

extension SpeechPageModel: ModelListing {}
extension CleanupPageModel: ModelListing {}
