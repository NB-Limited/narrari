import Darwin

// macOS's own answer to "is the screen being captured", looked up by name in the window server's framework,
// which has no public header; nothing links against it, so a macOS without it gives "unknown", not a crash.
public struct SkyLightScreenWatcher: ScreenWatcher {
    private typealias Present = @convention(c) () -> Bool

    private static let framework = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private let present: Present?

    public init() {
        let symbol = dlopen(Self.framework, RTLD_LAZY).flatMap { dlsym($0, "SLSIsScreenWatcherPresent") }
        present = symbol.map { unsafeBitCast($0, to: Present.self) }
        if present == nil { Log.failure("screen-watch-missing") }
    }

    public var isAvailable: Bool { present != nil }

    public func isWatched() -> Bool? {
        present?()
    }
}
