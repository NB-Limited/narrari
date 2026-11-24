import Foundation

public enum ModesCommand: Sendable, Equatable {
    public struct Fields: Sendable, Equatable {
        var name: String?
        var prompt: String?
        var cleanup: String?
        var speech: String?
    }

    case list(asJSON: Bool)
    case add(String, Fields)
    case edit(String, Fields)
    case remove(String)
    case makeDefault(String)
    case app(String, modes: [String], defaultID: String?)
    case unapp(String)

    static let mistake = "modes takes list [--json], add <name> [--prompt <id>] [--cleanup on|off] [--speech local|outside], "
        + "edit <id> [--name <name>] [and the same], remove <id>, default <id>, app <bundle id> <mode ids> [--default <id>] or unapp <bundle id>."

    private static let fieldFlags: Set<String> = ["--prompt", "--cleanup", "--speech"]

    init?(_ arguments: [String]) {
        let rest = arguments.dropFirst(2)
        switch (arguments.first, arguments.count) {
        case ("list", 1): self = .list(asJSON: false)
        case ("list", 2) where arguments[1] == "--json": self = .list(asJSON: true)
        case ("remove", 2): self = .remove(arguments[1])
        case ("default", 2): self = .makeDefault(arguments[1])
        case ("unapp", 2): self = .unapp(arguments[1])
        case ("add", 2...):
            guard let flags = SetupInput.flags(rest, allowed: Self.fieldFlags) else { return nil }
            self = .add(arguments[1], Self.fields(flags))
        case ("edit", 4...):
            guard let flags = SetupInput.flags(rest, allowed: Self.fieldFlags.union(["--name"])) else { return nil }
            self = .edit(arguments[1], Self.fields(flags))
        case ("app", 3...):
            let ids = rest.prefix { !$0.hasPrefix("--") }
            guard !ids.isEmpty, let flags = SetupInput.flags(rest.dropFirst(ids.count), allowed: ["--default"]) else { return nil }
            self = .app(arguments[1], modes: Array(ids), defaultID: flags["--default"])
        default: return nil
        }
    }

    private static func fields(_ flags: [String: String]) -> Fields {
        Fields(name: flags["--name"], prompt: flags["--prompt"], cleanup: flags["--cleanup"], speech: flags["--speech"])
    }

    @MainActor
    func run(in context: Command.Context) -> Command.Reply {
        let page = ModesPageModel(store: context.modes, prompts: context.prompts, settings: SettingsMirror(context.settings), apps: context.apps)
        page.appear()
        if case .list(let asJSON) = self { return .ok(asJSON ? SetupInput.json(page.book) : Self.rows(page)) }
        guard !page.file.isUnreadable else {
            return .failed("\(page.file.name) can't be read, so nothing was changed. Fix it, or start it fresh in Settings, Modes.\n")
        }
        let reply = change(page, in: context)
        if reply.status == 0 { context.announce(ModeStore.changeKey) }
        return reply
    }

    @MainActor
    private func change(_ page: ModesPageModel, in context: Command.Context) -> Command.Reply {
        switch self {
        case .list: return .ok("")
        case .add(let name, var fields):
            fields.name = name
            page.startAdding()
            return Self.save(fields, on: page)
        case .edit(let id, let fields):
            guard page.book.mode(id: id) != nil else { return Self.unknown(id) }
            page.startEditing(id)
            return Self.save(fields, on: page)
        case .remove(let id):
            guard page.book.mode(id: id) != nil else { return Self.unknown(id) }
            guard page.canDelete(id) else { return .failed(ModesPageModel.globalDefaultReason + "\n") }
            page.requestDeletion(id)
            page.confirmDeletion()
            return .refused(page.storeError, else: "Removed \(id).\n")
        case .makeDefault(let id):
            guard page.book.mode(id: id) != nil else { return Self.unknown(id) }
            page.globalDefaultID = id
            return .refused(page.storeError, else: "\(id) is now the default for every app.\n")
        case .app(let app, let ids, let defaultID): return Self.set(app, to: ids, defaultID: defaultID ?? ids[0], in: context.modes)
        case .unapp(let app): return Self.set(app, to: [], defaultID: "", in: context.modes)
        }
    }

    @MainActor
    private static func save(_ fields: Fields, on page: ModesPageModel) -> Command.Reply {
        guard var draft = page.draft else { return .failed("The mode could not be opened.\n") }
        if let name = fields.name { draft.name = name }
        if let prompt = fields.prompt {
            guard page.prompts.contains(where: { $0.id == prompt }) else {
                return .failed("\(prompt) is not a prompt. The prompts are: \(page.prompts.map(\.id).joined(separator: ", ")).\n")
            }
            draft.promptID = prompt
        }
        if let cleanup = fields.cleanup {
            guard let isOn = ["on": true, "off": false][cleanup] else { return .failed("--cleanup takes on or off.\n") }
            draft.isCleanupOn = isOn
        }
        if let speech = fields.speech {
            guard let choice = Mode.Speech(rawValue: speech) else { return .failed("--speech takes local or outside.\n") }
            if choice == .outside, draft.speech != .outside, !page.isOutsideReady {
                return .failed("The outside speech service is not set up. \(ModesPageModel.outsideReason)\n")
            }
            draft.speech = choice
        }
        page.draft = draft
        page.commit()
        return .refused(page.nameError ?? page.storeError, else: "Saved \(draft.name) as \(draft.id).\n")
    }

    // The same ModeBook rules the page's app list keeps: known modes only, and the default one of them.
    private static func set(_ app: String, to ids: [String], defaultID: String, in store: ModeStore) -> Command.Reply {
        do {
            try store.edit { try $0.setModes(for: app, ids: ids, defaultID: defaultID) }
        } catch ModeError.unknownMode(let id) {
            return unknown(id)
        } catch ModeError.defaultNotInList {
            return .failed("--default must be one of the modes given.\n")
        } catch {
            return .failed("modes.json could not be saved.\n")
        }
        return .ok(ids.isEmpty ? "\(app) uses the default mode now.\n" : "\(app) now uses \(ids.joined(separator: ", ")).\n")
    }

    private static func unknown(_ id: String) -> Command.Reply {
        .failed("No mode has the id \(id). See them with narrari modes list.\n")
    }

    @MainActor
    private static func rows(_ page: ModesPageModel) -> String {
        let book = page.book
        let modes = RecordKind.table(
            ["ID", "NAME", "DOES"],
            book.modes.map { [$0.id + ($0.id == book.globalDefaultID ? " *" : ""), $0.name, page.summary(of: $0)] }
        )
        let apps = book.apps.isEmpty ? "No app has modes of its own.\n" : RecordKind.table(
            ["APP", "MODES"],
            book.apps.keys.sorted().map { app in
                [app, book.modes(for: app).map { $0.id + ($0.id == book.defaultMode(for: app).id ? " *" : "") }.joined(separator: ", ")]
            }
        )
        return "\(modes)\nApps\n\(apps)\n* the default\n"
    }
}
