import Foundation

public enum TemplatesCommand: Sendable, Equatable {
    case list(asJSON: Bool)
    case show(String)
    case add(name: String, text: String)
    case duplicate(String)
    case edit(String, name: String?, text: String?)
    case remove(String)
    case makeDefault(String)

    static let mistake = "templates takes list [--json], show <id>, add <name> --text <file>, duplicate <id>, "
        + "edit <id> [--name <name>] [--text <file>], remove <id> or default <id>."

    init?(_ arguments: [String]) {
        let rest = arguments.dropFirst(2)
        switch (arguments.first, arguments.count) {
        case ("list", 1): self = .list(asJSON: false)
        case ("list", 2) where arguments[1] == "--json": self = .list(asJSON: true)
        case ("show", 2): self = .show(arguments[1])
        case ("duplicate", 2): self = .duplicate(arguments[1])
        case ("remove", 2): self = .remove(arguments[1])
        case ("default", 2): self = .makeDefault(arguments[1])
        case ("add", 4):
            guard let text = SetupInput.flags(rest, allowed: ["--text"])?["--text"] else { return nil }
            self = .add(name: arguments[1], text: text)
        case ("edit", 4...):
            guard let flags = SetupInput.flags(rest, allowed: ["--name", "--text"]) else { return nil }
            self = .edit(arguments[1], name: flags["--name"], text: flags["--text"])
        default: return nil
        }
    }

    @MainActor
    func run(in context: Command.Context) -> Command.Reply {
        let page = SummariesPageModel(
            folder: context.templates, settings: SettingsMirror(context.settings),
            summaryModels: SummaryModels(settings: context.settings, store: context.models)
        )
        page.readTemplates()
        if let error = page.error { return .failed(error + "\n") }
        let all = page.builtIn + page.yours
        switch self {
        case .list(let asJSON): return .ok(asJSON ? SetupInput.json(all.map(Self.fields)) : Self.rows(all, on: page))
        case .show(let id):
            guard let template = all.first(where: { $0.id == id }) else { return Self.unknown(id) }
            return .ok(SummaryTemplate.markdown(name: template.name, text: template.text))
        default:
            let reply = change(page, in: context)
            if reply.status == 0 {
                context.announce(SummariesPageModel.changeKey)
                context.announce(MeetingsSettings.summaryTemplate.key)
            }
            return reply
        }
    }

    @MainActor
    private func change(_ page: SummariesPageModel, in context: Command.Context) -> Command.Reply {
        switch self {
        case .list, .show: return .ok("")
        case .add(let name, let path):
            guard let text = SetupInput.text(at: path) else { return SetupInput.unreadable(path) }
            page.startAdding()
            return Self.save(page, id: context.templates.newID(for: name), name: name, text: text)
        case .duplicate(let id):
            guard let template = page.builtIn.first(where: { $0.id == id }) else { return .failed("\(id) is not a built-in template.\n") }
            page.startDuplicating(id)
            return Self.save(page, id: context.templates.newID(for: "\(template.name) copy"), name: nil, text: nil)
        case .edit(let id, let name, let path):
            if let refusal = Self.refusal(id, on: page) { return refusal }
            var text: String?
            if let path {
                guard let read = SetupInput.text(at: path) else { return SetupInput.unreadable(path) }
                text = read
            }
            page.startEditing(id)
            return Self.save(page, id: id, name: name, text: text)
        case .remove(let id):
            if let refusal = Self.refusal(id, on: page) { return refusal }
            page.requestDeletion(id)
            page.confirmDeletion()
            return .refused(page.error, else: "Removed \(id).\n")
        case .makeDefault(let id):
            guard (page.builtIn + page.yours).contains(where: { $0.id == id }) else { return Self.unknown(id) }
            page.makeDefault(id)
            return .ok("Meetings are now summed up with \(id).\n")
        }
    }

    // The id is the one the page saves under: the file name it makes from the name, or the template's own.
    @MainActor
    private static func save(_ page: SummariesPageModel, id: String, name: String?, text: String?) -> Command.Reply {
        if let name { page.draft?.name = name }
        if let text { page.draft?.text = text }
        page.commit()
        return .refused(page.nameError ?? page.textError ?? page.error, else: "Saved \(page.yours.first { $0.id == id }?.name ?? id) as \(id).\n")
    }

    @MainActor
    private static func refusal(_ id: String, on page: SummariesPageModel) -> Command.Reply? {
        if let template = page.builtIn.first(where: { $0.id == id }) {
            return .failed("\(template.name) is built in, so it can't be changed. Duplicate it to have a copy of your own.\n")
        }
        return page.yours.contains { $0.id == id } ? nil : unknown(id)
    }

    private static func unknown(_ id: String) -> Command.Reply {
        .failed("No template has the id \(id). See them with narrari templates list.\n")
    }

    private static func fields(_ template: SummaryTemplate) -> [String: String] {
        ["id": template.id, "name": template.name, "text": template.text]
    }

    @MainActor
    private static func rows(_ templates: [SummaryTemplate], on page: SummariesPageModel) -> String {
        let table = RecordKind.table(
            ["ID", "NAME", "KIND", "HEADINGS"],
            templates.map { template in
                let kind = page.builtIn.contains(template) ? "built in" : "yours"
                return [template.id + (template.id == page.defaultID ? " *" : ""), template.name, kind, template.headings]
            }
        )
        let unreadable = page.unreadable.isEmpty ? "" : "\nCan't be read: \(page.unreadable.joined(separator: ", "))\n"
        return table + unreadable + "\n* the default\n"
    }
}
