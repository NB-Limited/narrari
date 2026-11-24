import Foundation

public struct ModeResolver: Sendable, Equatable {
    private struct ManualSwitch: Sendable, Equatable {
        let app: String
        let modeID: String
    }

    private var manual: ManualSwitch?

    public init() {}

    public mutating func resolve(for app: String, in book: ModeBook) -> Mode {
        appChanged(to: app)
        if let manual, let mode = book.modes(for: app).first(where: { $0.id == manual.modeID }) { return mode }
        return book.defaultMode(for: app)
    }

    public mutating func cycle(for app: String, in book: ModeBook) -> Mode? {
        let list = book.modes(for: app)
        guard list.count > 1 else { return nil }
        let current = resolve(for: app, in: book)
        let next = list[((list.firstIndex { $0.id == current.id } ?? -1) + 1) % list.count]
        manual = ManualSwitch(app: app, modeID: next.id)
        return next
    }

    public mutating func select(_ id: String, for app: String, in book: ModeBook) -> Mode? {
        guard let mode = book.modes(for: app).first(where: { $0.id == id }) else { return nil }
        manual = ManualSwitch(app: app, modeID: mode.id)
        return mode
    }

    public mutating func appChanged(to app: String) {
        if manual?.app != app { manual = nil }
    }
}

public struct ModeChoice: Sendable, Equatable {
    public let app: String
    public let modes: [Mode]
    public let current: Mode

    public init(app: String, modes: [Mode], current: Mode) {
        self.app = app
        self.modes = modes
        self.current = current
    }
}
