import Foundation

// One row of a built-in list: its name, the short line under it and the full text it opens to.
public protocol ListedItem: Identifiable where ID == String {
    var name: String { get }
    var listDetail: String { get }
    var fullText: String { get }
}

public enum ListEditing: Sendable, Equatable {
    case new
    case item(String)
}

// A settings list of read-only built-in items, then the person's own, each edited in place: prompts and summary templates.
@MainActor
public protocol BuiltInList: AnyObject {
    associatedtype Item: ListedItem
    var builtIn: [Item] { get }
    var yours: [Item] { get }
    // Files of the person's own that could not be read, by id; each shows as a row that can be deleted.
    var unreadable: [String] { get }
    var editing: ListEditing? { get }
    var pendingDeletion: String? { get }
    func startAdding()
    func startDuplicating(_ id: String)
    func startEditing(_ id: String)
    func requestDeletion(_ id: String)
    func cancelDeletion()
    func confirmDeletion()
}

extension Prompt: ListedItem {
    public var listDetail: String {
        triggers.isEmpty ? "No trigger phrase" : "Trigger: \(triggers.joined(separator: ", "))"
    }

    public var fullText: String { instruction }
}

extension SummaryTemplate: ListedItem {
    public var listDetail: String { headings }
    public var fullText: String { text }
}
