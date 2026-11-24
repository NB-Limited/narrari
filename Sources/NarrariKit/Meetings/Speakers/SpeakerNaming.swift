import Foundation

// Who a speaker is, by the cosine distance between their print and the mean of a person's prints.
public enum SpeakerNaming {
    public enum Match: Equatable, Sendable {
        case named(UUID)
        // Left numbered, with the person offered first when renaming.
        case suggested(UUID)
    }

    // Measured 22 Nov 2026 on 5 two-track recordings: the same voice 0.05 to 0.16 from its mean, other voices 0.43 or more.
    public static let clear: Float = 0.30
    public static let near: Float = 0.40

    // Voices are each person's mean print. The closest pairs are decided first, so the closer of two speakers keeps a name.
    public static func matches(_ prints: [String: [Float]], voices: [UUID: [Float]]) -> [String: Match] {
        let pairs = prints.flatMap { speaker, values in
            voices.map { person, voice in (speaker: speaker, person: person, distance: distance(values, voice)) }
        }
        var matches: [String: Match] = [:]
        var named: Set<UUID> = []
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) where pair.distance <= near && matches[pair.speaker] == nil {
            if pair.distance <= clear, named.insert(pair.person).inserted {
                matches[pair.speaker] = .named(pair.person)
            } else {
                matches[pair.speaker] = .suggested(pair.person)
            }
        }
        return matches
    }

    static func voices(of people: [VoiceMemory.Person]) -> [UUID: [Float]] {
        Dictionary(uniqueKeysWithValues: people.compactMap { person in mean(person.prints.map(\.values)).map { (person.id, $0) } })
    }

    static func distance(_ first: [Float], _ second: [Float]) -> Float {
        let dot = zip(first, second).reduce(0) { $0 + $1.0 * $1.1 }
        let length = (first.reduce(0) { $0 + $1 * $1 } * second.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return length > 0 ? 1 - dot / length : 1
    }

    static func mean(_ prints: [[Float]]) -> [Float]? {
        guard let first = prints.first else { return nil }
        return prints.dropFirst().reduce(first) { zip($0, $1).map(+) }.map { $0 / Float(prints.count) }
    }

    static func numberedName(_ number: Int) -> String {
        "Speaker \(number)"
    }
}
