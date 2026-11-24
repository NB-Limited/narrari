extension Array where Element: Equatable {
    // A value set outside the presets joins them in its place, so the picker still shows it as chosen.
    func including(_ current: Element, inOrder isBefore: (Element, Element) -> Bool) -> [Element] {
        guard !contains(current) else { return self }
        var options = self
        options.insert(current, at: firstIndex { isBefore(current, $0) } ?? endIndex)
        return options
    }
}
