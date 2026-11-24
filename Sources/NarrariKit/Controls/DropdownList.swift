import Foundation

// An open dropdown list: which row is highlighted, moved by the arrow keys, the pointer or typing a name.
public struct DropdownList: Equatable, Sendable {
    // Letters typed within this many seconds of each other spell one name.
    public static let typingPause: TimeInterval = 1

    public let titles: [String]
    public private(set) var highlighted: Int?
    private var typed = ""
    private var lastTyped: TimeInterval?

    public init(titles: [String], chosen: Int?) {
        self.titles = titles
        highlighted = chosen.flatMap { titles.indices.contains($0) ? $0 : nil } ?? (titles.isEmpty ? nil : 0)
    }

    // Stops at either end, as a menu does.
    public mutating func move(by offset: Int) {
        guard !titles.isEmpty else { return }
        guard let current = highlighted else {
            highlighted = offset > 0 ? 0 : titles.count - 1
            return
        }
        highlighted = min(max(current + offset, 0), titles.count - 1)
    }

    public mutating func moveToEnd(last: Bool) {
        guard !titles.isEmpty else { return }
        highlighted = last ? titles.count - 1 : 0
    }

    public mutating func highlight(_ index: Int) {
        guard titles.indices.contains(index) else { return }
        highlighted = index
    }

    // The same letter typed again steps through the names that start with it.
    public mutating func type(_ text: String, at time: TimeInterval) {
        guard !text.isEmpty else { return }
        let isFresh = lastTyped.map { time - $0 > Self.typingPause } ?? true
        typed = (isFresh ? "" : typed) + text
        lastTyped = time
        if let match = firstIndex(startingWith: typed, from: 0) {
            highlighted = match
            return
        }
        guard let letter = typed.first, typed.allSatisfy({ $0 == letter }) else { return }
        let start = (highlighted ?? -1) + 1
        if let next = firstIndex(startingWith: String(letter), from: start) ?? firstIndex(startingWith: String(letter), from: 0) {
            highlighted = next
        }
    }

    private func firstIndex(startingWith prefix: String, from start: Int) -> Int? {
        titles.indices.dropFirst(start).first { index in
            titles[index].range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
