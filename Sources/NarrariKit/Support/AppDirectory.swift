import AppKit

@MainActor
public final class AppDirectory {
    public struct App: Identifiable {
        public let bundleIdentifier: String
        public let name: String
        public let icon: NSImage?

        public var id: String { bundleIdentifier }
    }

    // An app the picker offers; its icon is loaded only when its row shows.
    public struct Listing: Sendable, Identifiable, Equatable {
        public let bundleIdentifier: String
        public let name: String
        public let url: URL

        public var id: String { bundleIdentifier }
    }

    private final class Entry {
        let app: App
        init(_ app: App) { self.app = app }
    }

    public static let shared = AppDirectory()

    public static let defaultFolders: [URL] = [
        URL(filePath: "/Applications"), URL(filePath: "/Applications/Utilities"),
        URL(filePath: "/System/Applications"), URL(filePath: "/System/Applications/Utilities"),
        URL.homeDirectory.appending(path: "Applications")
    ]

    // History names only a handful of apps, so the limit is never felt; evicted ones are looked up again.
    private static let cacheLimit = 200

    private let cache = NSCache<NSString, Entry>()
    private let folders: [URL]

    public init(folders: [URL] = AppDirectory.defaultFolders) {
        self.folders = folders
        cache.countLimit = Self.cacheLimit
    }

    public func app(for bundleIdentifier: String) -> App {
        if let known = cache.object(forKey: bundleIdentifier as NSString) { return known.app }
        let found: App
        if !bundleIdentifier.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            found = App(bundleIdentifier: bundleIdentifier, name: Self.displayName(of: url), icon: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            found = App(bundleIdentifier: bundleIdentifier, name: bundleIdentifier.isEmpty ? "Unknown app" : bundleIdentifier, icon: nil)
        }
        cache.setObject(Entry(found), forKey: bundleIdentifier as NSString)
        return found
    }

    public func name(for bundleIdentifier: String) -> String {
        app(for: bundleIdentifier).name
    }

    public func icon(for listing: Listing) -> NSImage {
        NSWorkspace.shared.icon(forFile: listing.url.path)
    }

    // The apps in the usual folders plus any running app with a window, by name, read off the main actor.
    public func installedAndRunning() async -> [Listing] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        let own = Bundle.main.bundleIdentifier
        let folders = folders
        return await Task.detached(priority: .userInitiated) {
            Self.scan(folders, adding: running, excluding: own)
        }.value
    }

    private nonisolated static func scan(_ folders: [URL], adding running: [URL], excluding own: String?) -> [Listing] {
        let manager = FileManager.default
        let bundles = folders.flatMap { folder in
            ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        }
        var seen: Set<String> = own.map { [$0] } ?? []
        let listings = (bundles + running).compactMap { bundle -> Listing? in
            guard let identifier = Bundle(url: bundle)?.bundleIdentifier, seen.insert(identifier).inserted else { return nil }
            return Listing(bundleIdentifier: identifier, name: displayName(of: bundle), url: bundle)
        }
        return listings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func displayName(of bundle: URL) -> String {
        let name = FileManager.default.displayName(atPath: bundle.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
