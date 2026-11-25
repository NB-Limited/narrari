import Foundation

// The owner as a calendar or a call's list may spell them: "Novak, Milena M." is Mila Novak, by a word in common and
// each other word of the owner's name starting as one of the listed name's does. Initials are left out.
public struct OwnerName: Sendable {
    private let name: String

    public init(_ name: String) {
        self.name = name
    }

    public func matches(_ listed: String) -> Bool {
        if listed.caseInsensitiveCompare(name) == .orderedSame { return true }
        let own = Self.words(name), other = Self.words(listed)
        guard !own.isDisjoint(with: other) else { return false }
        let starts = Set(other.subtracting(own).compactMap(\.first))
        return own.subtracting(other).allSatisfy { $0.first.map(starts.contains) == true }
    }

    private static func words(_ name: String) -> Set<String> {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.split { !$0.isLetter }.filter { $0.count > 1 }.map(String.init))
    }
}
