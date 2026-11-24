import Foundation

public enum PeopleCommand: Sendable, Equatable {
    case list(asJSON: Bool)
    case rename(UUID, to: String)
    case forget(UUID)

    static let mistake = "people takes list [--json], rename <id> <name> or forget <id>."

    init?(_ arguments: [String]) {
        let id = arguments.dropFirst().first.flatMap(UUID.init(uuidString:))
        let name = arguments.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        switch (arguments.first, arguments.count, id) {
        case ("list", 1, _): self = .list(asJSON: false)
        case ("list", 2, _) where arguments[1] == "--json": self = .list(asJSON: true)
        case ("rename", 3..., let id?) where !name.isEmpty: self = .rename(id, to: name)
        case ("forget", 2, let id?): self = .forget(id)
        default: return nil
        }
    }

    // Voice prints never leave people.json; only names and ids are shown.
    @MainActor
    func run(in context: Command.Context) async -> Command.Reply {
        let page = PeoplePageModel(
            settings: SettingsMirror(context.settings), memory: context.voices,
            renaming: SpeakerRenaming(store: context.meetings, memory: context.voices, settings: context.settings)
        )
        await page.appear()
        switch self {
        case .list(let asJSON):
            let people = page.people.map { ["id": $0.id.uuidString, "name": $0.name] }
            guard !asJSON else { return .ok(SetupInput.json(people)) }
            return .ok(people.isEmpty ? "No people yet.\n" : RecordKind.table(["ID", "NAME"], people.map { [$0["id"] ?? "", $0["name"] ?? ""] }))
        case .rename(let id, let name):
            guard page.people.contains(where: { $0.id == id }) else { return Self.unknown(id) }
            await page.rename(id, to: name)
            guard page.people.contains(where: { $0.id == id && $0.name == name }) else { return .failed("The person could not be renamed.\n") }
            context.announce(PeoplePageModel.changeKey)
            return .ok("Renamed to \(name).\n")
        case .forget(let id):
            guard let person = page.people.first(where: { $0.id == id }) else { return Self.unknown(id) }
            await page.forget(id)
            guard !page.people.contains(where: { $0.id == id }) else { return .failed("\(person.name) could not be forgotten.\n") }
            context.announce(PeoplePageModel.changeKey)
            return .ok("Forgot \(person.name). Past meetings keep the name.\n")
        }
    }

    private static func unknown(_ id: UUID) -> Command.Reply {
        .failed("No person has the id \(id.uuidString). See them with narrari people list.\n")
    }
}
