import Foundation

public enum ModeError: Error, Equatable {
    case unknownMode(String)
    case duplicateMode(String)
    case isGlobalDefault
    case defaultNotInList
}

public struct AppModes: Codable, Sendable, Equatable {
    public var modeIDs: [String]
    public var defaultID: String

    public init(modeIDs: [String], defaultID: String) {
        self.modeIDs = modeIDs
        self.defaultID = defaultID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modeIDs = try container.decodeIfPresent([String].self, forKey: .modeIDs) ?? []
        defaultID = try container.decodeIfPresent(String.self, forKey: .defaultID) ?? ""
    }
}

public struct ModeBook: Codable, Sendable, Equatable {
    public private(set) var modes = [Mode.dictation]
    public private(set) var apps: [String: AppModes] = [:]
    public private(set) var globalDefaultID = Mode.dictation.id

    public var globalDefault: Mode { mode(id: globalDefaultID) ?? .dictation }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modes = try container.decodeIfPresent([Mode].self, forKey: .modes) ?? [.dictation]
        apps = try container.decodeIfPresent([String: AppModes].self, forKey: .apps) ?? [:]
        globalDefaultID = try container.decodeIfPresent(String.self, forKey: .globalDefaultID) ?? Mode.dictation.id
        repair()
    }

    public func mode(id: String) -> Mode? {
        modes.first { $0.id == id }
    }

    public func modes(for app: String) -> [Mode] {
        (apps[app]?.modeIDs ?? []).compactMap(mode(id:))
    }

    public func defaultMode(for app: String) -> Mode {
        apps[app].flatMap { mode(id: $0.defaultID) } ?? globalDefault
    }

    public mutating func add(_ mode: Mode) throws(ModeError) {
        guard self.mode(id: mode.id) == nil else { throw .duplicateMode(mode.id) }
        modes.append(mode)
    }

    public mutating func update(_ mode: Mode) throws(ModeError) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { throw .unknownMode(mode.id) }
        modes[index] = mode
    }

    public mutating func delete(_ id: String) throws(ModeError) {
        guard id != globalDefaultID else { throw .isGlobalDefault }
        modes.removeAll { $0.id == id }
        repair()
    }

    // An empty list removes the app, so it falls back to the global default.
    public mutating func setModes(for app: String, ids: [String], defaultID: String) throws(ModeError) {
        if let unknown = ids.first(where: { mode(id: $0) == nil }) { throw .unknownMode(unknown) }
        guard ids.isEmpty || ids.contains(defaultID) else { throw .defaultNotInList }
        apps[app] = AppModes(modeIDs: ids, defaultID: defaultID)
        repair()
    }

    public mutating func setGlobalDefault(_ id: String) throws(ModeError) {
        guard mode(id: id) != nil else { throw .unknownMode(id) }
        globalDefaultID = id
    }

    // Keeps every list and default pointing at a mode that exists, also for a file edited by hand.
    private mutating func repair() {
        if mode(id: globalDefaultID) == nil {
            if mode(id: Mode.dictation.id) == nil { modes.insert(.dictation, at: 0) }
            globalDefaultID = Mode.dictation.id
        }
        let known = Set(modes.map(\.id))
        apps = apps.compactMapValues { entry in
            var seen = Set<String>()
            let ids = entry.modeIDs.filter { known.contains($0) && seen.insert($0).inserted }
            guard let first = ids.first else { return nil }
            return AppModes(modeIDs: ids, defaultID: ids.contains(entry.defaultID) ? entry.defaultID : first)
        }
    }
}

public struct ModeStore: Sendable {
    public static let shared = ModeStore(root: AppPaths.applicationSupport)
    public static let changeKey = "modes"

    public let file: JSONFile<ModeBook>

    public init(root: URL) {
        file = JSONFile(root.appending(path: "modes.json"), empty: ModeBook())
    }

    public func load() throws -> ModeBook {
        try file.load()
    }

    @discardableResult
    public func edit(_ change: (inout ModeBook) throws -> Void) throws -> ModeBook {
        let book = try file.edit(change)
        SettingsChanges.post(Self.changeKey)
        return book
    }
}
