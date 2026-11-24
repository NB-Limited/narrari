import Foundation

// The narrari command: the app's own executable, run with a command word instead of as the app.
public enum Command: Sendable, Equatable {
    case help
    case mistake(String)
    case logs(last: String)
    case doctor
    case listSettings
    case getSetting(String)
    case setSetting(String, to: String)
    case resetSetting(String)
    case list(RecordKind, since: Date?, asJSON: Bool)
    case show(RecordKind, UUID, part: MeetingPart?)
    case search(RecordKind, String)
    case shortcuts(ShortcutsCommand)
    case dictionary(DictionaryCommand)
    case prompts(PromptsCommand)
    case modes(ModesCommand)
    case templates(TemplatesCommand)
    case people(PeopleCommand)
    case mcp

    public struct Reply: Sendable, Equatable {
        public let output: String
        public let errors: String
        public let status: Int32

        static func ok(_ output: String) -> Reply { Reply(output: output, errors: "", status: 0) }
        static func failed(_ errors: String) -> Reply { Reply(output: "", errors: errors, status: 1) }
    }

    public struct Context: Sendable {
        let settings: SettingsStore
        let models: ModelStore
        let history: HistoryStore
        let meetings: MeetingStore
        let apps: AppDirectory
        let dataFolder: URL
        let dictionary: DictionaryStore
        let prompts: PromptStore
        let modes: ModeStore
        let templates: SummaryTemplateFolder
        let voices: VoiceMemory
        // Tells a running Narrari which setting or file changed, so it shows and uses it at once.
        let announce: @Sendable (String) -> Void

        public init(
            settings: SettingsStore, models: ModelStore, history: HistoryStore, meetings: MeetingStore, apps: AppDirectory, dataFolder: URL,
            dictionary: DictionaryStore, prompts: PromptStore, modes: ModeStore, templates: SummaryTemplateFolder, voices: VoiceMemory,
            announce: @escaping @Sendable (String) -> Void
        ) {
            self.settings = settings
            self.models = models
            self.history = history
            self.meetings = meetings
            self.apps = apps
            self.dataFolder = dataFolder
            self.dictionary = dictionary
            self.prompts = prompts
            self.modes = modes
            self.templates = templates
            self.voices = voices
            self.announce = announce
        }
    }

    static let usage = """
        Usage: narrari <command>

          logs [--last <time>]                       Narrari's log lines, oldest first. Time such as 30m, 1h or 2d; 1h if left out.
          doctor                                     What someone helping you needs to know. Exits 1 when a line is marked !.
          settings                                   Every setting with its value and default; * marks the ones changed.
          settings get <key>                         One setting's value.
          settings set <key> <value>                 Change a setting. Narrari, if open, uses it at once.
          settings reset <key>                       Put a setting back to its default.
          shortcuts [--json]                         Every shortcut. set <action> <keys> as ctrl+opt+m or ⌃⌥M, or right-cmd for
                                                     dictation; clear <action> removes one.
          dictionary list [--json]                   Your words, replacements and spoken marks. Also add|remove <word>,
                                                     replace <phrase> <text>, unreplace <phrase>, mark <phrase> <mark>, unmark <phrase>.
          prompts list [--json]                      Clean-up prompts. Also show|duplicate|remove <id>, add <name> --text <file>
                                                     [--triggers <phrases>], edit <id> [--name] [--text] [--triggers].
          modes list [--json]                        Modes and the apps that use them. Also add <name> [--prompt <id>]
                                                     [--cleanup on|off] [--speech local|outside], edit <id> [--name] [the same],
                                                     remove|default <id>, app <bundle id> <mode ids> [--default <id>], unapp <bundle id>.
          templates list [--json]                    Summary templates. Also show|duplicate|remove|default <id>,
                                                     add <name> --text <file>, edit <id> [--name] [--text].
          people list [--json]                       People known by voice. Also rename <id> <name>, forget <id>.
          meetings list [--since <day>] [--json]     Meetings, newest first, from a day such as 2026-11-22 on.
          meetings show <id> [--part <part>]         One meeting, or one part of it: summary, notes or transcript.
          meetings search <text>                     Meetings with the text in their title, names, notes, summary or transcript.
          dictations list [--since <day>] [--json]   Dictations, newest first, from a day such as 2026-11-22 on.
          dictations show <id>                       One dictation's text.
          dictations search <text>                   Dictations with the text in what was said or the app it went to.
          mcp                                        Lets an AI tool list, search and read meetings and dictations, read-only.

        A change goes through the same checks as in Settings, and Narrari, if open, shows and uses it at once.
        A <file> of - reads stdin.

        """

    // Nil when the arguments are the app's own: none, or the flags macOS and Xcode pass at launch, so the app starts as before.
    public init?(arguments: [String]) {
        guard let word = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch word {
        case "help", "-h", "--help": self = .help
        case "logs": self = Self.logs(rest)
        case "doctor": self = rest.isEmpty ? .doctor : .mistake("doctor takes no arguments.")
        case "settings": self = Self.settings(rest)
        case "meetings": self = Self.records(.meetings, rest)
        case "dictations": self = Self.records(.dictations, rest)
        case "shortcuts": self = ShortcutsCommand(rest).map(Command.shortcuts) ?? .mistake(ShortcutsCommand.mistake)
        case "dictionary": self = DictionaryCommand(rest).map(Command.dictionary) ?? .mistake(DictionaryCommand.mistake)
        case "prompts": self = PromptsCommand(rest).map(Command.prompts) ?? .mistake(PromptsCommand.mistake)
        case "modes": self = ModesCommand(rest).map(Command.modes) ?? .mistake(ModesCommand.mistake)
        case "templates": self = TemplatesCommand(rest).map(Command.templates) ?? .mistake(TemplatesCommand.mistake)
        case "people": self = PeopleCommand(rest).map(Command.people) ?? .mistake(PeopleCommand.mistake)
        case "mcp": self = rest.isEmpty ? .mcp : .mistake("mcp takes no arguments.")
        case _ where word.hasPrefix("-"): return nil
        default: self = .mistake("\(word) is not a narrari command.")
        }
    }

    private static func logs(_ arguments: [String]) -> Command {
        switch arguments.count {
        case 0: return .logs(last: "1h")
        case 2 where arguments[0] == "--last" && arguments[1].wholeMatch(of: /[1-9][0-9]*[mhd]/) != nil:
            return .logs(last: arguments[1])
        default: return .mistake("logs takes --last and a time such as 30m, 1h or 2d.")
        }
    }

    private static func settings(_ arguments: [String]) -> Command {
        switch (arguments.first, arguments.count) {
        case (nil, _): .listSettings
        case ("get", 2): .getSetting(arguments[1])
        case ("set", 3): .setSetting(arguments[1], to: arguments[2])
        case ("reset", 2): .resetSetting(arguments[1])
        default: .mistake("settings takes get <key>, set <key> <value> or reset <key>.")
        }
    }

    private static func records(_ kind: RecordKind, _ arguments: [String]) -> Command {
        let rest = Array(arguments.dropFirst())
        let parsed: Command? = switch arguments.first {
        case "list": list(kind, rest)
        case "show": show(kind, rest)
        case "search" where !rest.isEmpty: .search(kind, rest.joined(separator: " "))
        default: nil
        }
        return parsed ?? .mistake(
            "\(kind.rawValue) takes list [--since <day>] [--json], show <id>\(kind == .meetings ? " [--part <part>]" : "") or search <text>."
        )
    }

    private static func list(_ kind: RecordKind, _ arguments: [String]) -> Command? {
        var since: Date?
        var asJSON = false
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch flag {
            case "--json" where !asJSON: asJSON = true
            case "--since" where since == nil:
                guard let day = rest.popFirst().flatMap(RecordKind.day) else { return nil }
                since = day
            default: return nil
            }
        }
        return .list(kind, since: since, asJSON: asJSON)
    }

    private static func show(_ kind: RecordKind, _ arguments: [String]) -> Command? {
        guard let id = arguments.first.flatMap(UUID.init(uuidString:)) else { return nil }
        switch arguments.count {
        case 1: return .show(kind, id, part: nil)
        case 3 where kind == .meetings && arguments[1] == "--part":
            return MeetingPart(rawValue: arguments[2]).map { .show(kind, id, part: $0) }
        default: return nil
        }
    }

    // Run through a symlink such as ~/.local/bin/narrari, the process finds no bundle: no bundle id, so not the app's
    // defaults or log. Starting again from the real path inside Narrari.app gives it all three; it returns only if that fails.
    public static func reopenInsideBundle() {
        guard Bundle.main.bundleIdentifier == nil,
              let link = Bundle.main.executableURL,
              case let real = link.resolvingSymlinksInPath().path, real != link.path
        else { return }
        let arguments = [real] + CommandLine.arguments.dropFirst()
        var pointers = arguments.map { strdup($0) } + [nil]
        execv(real, &pointers)
    }

    @MainActor
    public func run(in context: Context) async -> Reply {
        switch self {
        case .help: .ok(Self.usage)
        case .mistake(let problem): Reply(output: "", errors: "\(problem)\n\n\(Self.usage)", status: 2)
        case .logs(let last): AppLog.show(last: last)
        case .doctor: await DoctorReport(facts: DoctorFacts.collect(in: context)).reply
        case .listSettings: .ok(SettingsCommand.list(context.settings))
        case .getSetting(let key): SettingsCommand.get(key, in: context.settings)
        case .setSetting(let key, let value): SettingsCommand.set(key, to: value, in: context)
        case .resetSetting(let key): SettingsCommand.reset(key, in: context)
        case .list(let kind, let since, let asJSON):
            await Self.reading(kind) { .ok(try await kind.command.list(since: since, limit: nil, asJSON: asJSON, in: context)) }
        case .show(let kind, let id, let part):
            await Self.reading(kind) {
                try await kind.command.read(id, part: part, in: context).map(Reply.ok)
                    ?? .failed("No \(kind.singular) has the id \(id.uuidString).\n")
            }
        case .search(let kind, let text):
            await Self.reading(kind) { .ok(try await kind.command.search(text, limit: nil, in: context)) }
        case .shortcuts(let command): command.run(in: context)
        case .dictionary(let command): command.run(in: context)
        case .prompts(let command): command.run(in: context)
        case .modes(let command): command.run(in: context)
        case .templates(let command): command.run(in: context)
        case .people(let command): await command.run(in: context)
        case .mcp: await Self.serve(context)
        }
    }

    // Until the client closes stdin; every reply has gone to stdout by then, so the command's own output is empty.
    @MainActor
    private static func serve(_ context: Context) async -> Reply {
        await Connector(context: context).serve(FileHandle.standardInput.bytes) { FileHandle.standardOutput.write($0) }
        return .ok("")
    }

    @MainActor
    private static func reading(_ kind: RecordKind, _ read: () async throws -> Reply) async -> Reply {
        do {
            return try await read()
        } catch {
            return .failed(error.problem(or: kind.readFailed).message + "\n")
        }
    }
}
