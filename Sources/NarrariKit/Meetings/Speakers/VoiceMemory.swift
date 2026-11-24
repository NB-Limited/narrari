import Foundation

// The people Narrari knows by voice, in people.json: names and voice prints, numbers only, never audio.
public actor VoiceMemory {
    public struct Person: Codable, Sendable, Equatable, Identifiable {
        // One meeting's print; the meeting is kept so "not this person" can take it back.
        public struct Print: Codable, Sendable, Equatable {
            public let meeting: UUID
            public let values: [Float]
        }

        public let id: UUID
        public var name: String
        public var isOwner: Bool
        public var prints: [Print]
    }

    static let printLimit = 8

    private let file: JSONFile<[Person]>

    public init(folder: URL) {
        file = JSONFile(folder.appending(path: "people.json"), empty: [])
    }

    public func people() throws -> [Person] {
        try file.load()
    }

    // The owner is made the first time a print is learned for them, named as the Mac account is.
    func owner(named name: String) throws -> Person {
        if let owner = try people().first(where: \.isOwner) { return owner }
        return try add(Person(id: UUID(), name: name, isOwner: true, prints: []))
    }

    func newPerson(named name: String) throws -> Person {
        try add(Person(id: UUID(), name: name, isOwner: false, prints: []))
    }

    // A meeting gives a person one print: learning from it again replaces the one it gave, and past 8 the oldest goes.
    func learn(_ values: [Float], from meeting: UUID, for person: UUID) throws {
        try change(person) { found in
            found.prints.removeAll { $0.meeting == meeting }
            found.prints.append(Person.Print(meeting: meeting, values: values))
            found.prints = Array(found.prints.suffix(Self.printLimit))
        }
    }

    func unlearn(printFrom meeting: UUID, for person: UUID) throws {
        try change(person) { $0.prints.removeAll { $0.meeting == meeting } }
    }

    public func rename(_ person: UUID, to name: String) throws {
        try change(person) { $0.name = name }
    }

    func delete(_ person: UUID) throws {
        try file.edit { $0.removeAll { $0.id == person } }
    }

    private func add(_ person: Person) throws -> Person {
        try file.edit { $0.append(person) }
        return person
    }

    private func change(_ person: UUID, _ edit: (inout Person) -> Void) throws {
        try file.edit { people in
            guard let index = people.firstIndex(where: { $0.id == person }) else { return }
            edit(&people[index])
        }
    }
}
