import Foundation

public enum PromptsCommand: Sendable, Equatable {
    case list(asJSON: Bool)
    case show(String)
    case add(name: String, text: String, triggers: String?)
    case duplicate(String)
    case edit(String, name: String?, text: String?, triggers: String?)
    case remove(String)

    static let mistake = "prompts takes list [--json], show <id>, add <name> --text <file> [--triggers <phrases>], duplicate <id>, "
        + "edit <id> [--name <name>] [--text <file>] [--triggers <phrases>] or remove <id>."

    init?(_ arguments: [String]) {
        let rest = arguments.dropFirst(2)
        switch (arguments.first, arguments.count) {
        case ("list", 1): self = .list(asJSON: false)
        case ("list", 2) where arguments[1] == "--json": self = .list(asJSON: true)
        case ("show", 2): self = .show(arguments[1])
        case ("duplicate", 2): self = .duplicate(arguments[1])
        case ("remove", 2): self = .remove(arguments[1])
        case ("add", 2...):
            guard let flags = SetupInput.flags(rest, allowed: ["--text", "--triggers"]), let text = flags["--text"] else { return nil }
            self = .add(name: arguments[1], text: text, triggers: flags["--triggers"])
        case ("edit", 4...):
            guard let flags = SetupInput.flags(rest, allowed: ["--name", "--text", "--triggers"]) else { return nil }
            self = .edit(arguments[1], name: flags["--name"], text: flags["--text"], triggers: flags["--triggers"])
        default: return nil
        }
    }

    @MainActor
    func run(in context: Command.Context) -> Command.Reply {
        let page = PromptsPageModel(store: context.prompts)
        page.appear()
        switch self {
        case .list(let asJSON):
            let all = page.builtIn + page.yours
            return .ok(asJSON ? SetupInput.json(all) : Self.rows(all, builtIn: page.builtIn))
        case .show(let id):
            guard let prompt = (page.builtIn + page.yours).first(where: { $0.id == id }) else { return Self.unknown(id) }
            return .ok(prompt.instruction + "\n")
        default:
            guard !page.file.isUnreadable else {
                return .failed("\(page.file.name) can't be read, so nothing was changed. Fix it, or start it fresh in Settings, Prompts.\n")
            }
            let reply = change(page)
            if reply.status == 0 { context.announce(PromptStore.changeKey) }
            return reply
        }
    }

    @MainActor
    private func change(_ page: PromptsPageModel) -> Command.Reply {
        switch self {
        case .list, .show: return .ok("")
        case .add(let name, let path, let triggers):
            guard let text = SetupInput.text(at: path) else { return SetupInput.unreadable(path) }
            page.startAdding()
            return Self.save(page, name: name, text: text, triggers: triggers)
        case .duplicate(let id):
            guard page.builtIn.contains(where: { $0.id == id }) else { return .failed("\(id) is not a built-in prompt.\n") }
            page.startDuplicating(id)
            return Self.save(page, name: nil, text: nil, triggers: nil)
        case .edit(let id, let name, let path, let triggers):
            if let refusal = Self.refusal(id, on: page) { return refusal }
            var text: String?
            if let path {
                guard let read = SetupInput.text(at: path) else { return SetupInput.unreadable(path) }
                text = read
            }
            page.startEditing(id)
            return Self.save(page, name: name, text: text, triggers: triggers)
        case .remove(let id):
            if let refusal = Self.refusal(id, on: page) { return refusal }
            page.requestDeletion(id)
            page.confirmDeletion()
            return .refused(page.storeError, else: "Removed \(id).\n")
        }
    }

    @MainActor
    private static func save(_ page: PromptsPageModel, name: String?, text: String?, triggers: String?) -> Command.Reply {
        guard let id = page.draft?.id else { return .failed("The prompt could not be opened.\n") }
        if let name { page.draft?.name = name }
        if let text { page.draft?.instruction = text }
        if let triggers { page.draft?.triggers = triggers }
        page.commit()
        let saved = page.yours.first { $0.id == id }
        return .refused(page.nameError ?? page.instructionError ?? page.triggerError ?? page.storeError, else: "Saved \(saved?.name ?? id) as \(id).\n")
    }

    @MainActor
    private static func refusal(_ id: String, on page: PromptsPageModel) -> Command.Reply? {
        if let prompt = page.builtIn.first(where: { $0.id == id }) {
            return .failed("\(prompt.name) is built in, so it can't be changed. Duplicate it to have a copy of your own.\n")
        }
        return page.yours.contains { $0.id == id } ? nil : unknown(id)
    }

    private static func unknown(_ id: String) -> Command.Reply {
        .failed("No prompt has the id \(id). See them with narrari prompts list.\n")
    }

    private static func rows(_ prompts: [Prompt], builtIn: [Prompt]) -> String {
        RecordKind.table(
            ["ID", "NAME", "KIND", "TRIGGERS"],
            prompts.map { prompt in
                [prompt.id, prompt.name, builtIn.contains(prompt) ? "built in" : "yours", prompt.triggers.joined(separator: ", ")]
            }
        )
    }
}
