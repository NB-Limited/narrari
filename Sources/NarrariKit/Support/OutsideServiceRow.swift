import Foundation

// The outside service as the only row of its side of the model area: its radio, one line that says where the words
// go, and Set up or the pencil.
public struct OutsideServiceRow: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case notSetUp
        case ready
        case inUse
        case problem(String)
    }

    public let status: Status
    public let name: String
    private let host: String
    private let model: String
    private let sends: String
    private let isChoice: Bool
    private let isEditing: Bool

    // Speech sends audio and leaves the choice to modes; clean-up sends text and is chosen in its list.
    public init(status: Status, job: ModelJob, address: String, model: String, isEditing: Bool) {
        self.status = status
        name = job == .speech ? "Speech service" : "Chat service"
        host = URLComponents(string: address.trimmingCharacters(in: .whitespaces))?.host ?? address
        self.model = model.trimmingCharacters(in: .whitespaces)
        sends = job == .speech ? "audio" : "text"
        isChoice = job == .cleanup
        self.isEditing = isEditing
    }

    public var mark: ChoiceMark {
        guard isChoice else { return .unavailable }
        return switch status {
        case .inUse, .problem: .chosen
        case .ready: .available
        case .notSetUp: .unavailable
        }
    }

    public var offersSetUp: Bool { !isEditing && status == .notSetUp }

    public var showsEditButton: Bool { !isEditing && status != .notSetUp }

    // "Text leaves this Mac", then "chat.example.com, small-chat-1, text leaves this Mac" once set up.
    public var summary: String {
        let leaves = "\(sends) leaves this Mac"
        guard status != .notSetUp else { return leaves.prefix(1).uppercased() + leaves.dropFirst() }
        return ([host, model].filter { !$0.isEmpty } + [leaves]).joined(separator: ", ")
    }

    public var failure: String? {
        if case .problem(let message) = status { return message }
        return nil
    }
}
