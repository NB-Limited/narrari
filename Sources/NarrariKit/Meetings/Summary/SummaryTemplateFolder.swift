import CryptoKit
import Foundation

// A built-in is copied in when missing; one still as shipped, by its fingerprint in .shipped.json, takes the newer text.
public struct SummaryTemplateFolder: Sendable {
    public static let builtInIDs = ["general", "one-to-one", "client-call"]

    public static let bundled: [String: String] = Dictionary(uniqueKeysWithValues: builtInIDs.compactMap { id in
        guard let url = Bundle.module.url(forResource: id, withExtension: "md", subdirectory: "SummaryTemplates") else {
            Log.failure("summary-template-missing")
            return nil
        }
        do {
            return (id, try String(contentsOf: url, encoding: .utf8))
        } catch {
            Log.failure("summary-template-unreadable-bundled", error: error)
            return nil
        }
    })

    public let url: URL
    private let builtIns: [String: String]
    private var shipped: JSONFile<[String: String]> { JSONFile(url.appending(path: ".shipped.json"), empty: [:]) }

    public init(url: URL, builtIns: [String: String]) {
        self.url = url
        self.builtIns = builtIns
    }

    public struct Listing: Sendable {
        public let templates: [SummaryTemplate]
        // Files that could not be read as a template, by id, so the page shows them instead of dropping them.
        public let unreadable: [String]
    }

    public func all() throws -> [SummaryTemplate] {
        try listing().templates
    }

    public func listing() throws -> Listing {
        try refresh()
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var templates: [SummaryTemplate] = []
        var unreadable: [String] = []
        for file in files where file.pathExtension == "md" {
            do {
                templates.append(try read(file))
            } catch {
                Log.failure("summary-template-unreadable", error: error)
                unreadable.append(file.deletingPathExtension().lastPathComponent)
            }
        }
        return Listing(
            templates: templates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            unreadable: unreadable.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    public func template(_ id: String) throws -> SummaryTemplate {
        try refresh()
        let file = url.appending(path: id + ".md")
        guard FileManager.default.fileExists(atPath: file.path) else { throw SummaryTemplateError.missing }
        return try read(file)
    }

    // A meeting whose template was deleted uses the default instead, and the shipped default when that is gone too.
    public func template(_ id: String, orElse fallback: String) throws -> SummaryTemplate {
        try refresh()
        let found = [id, fallback].first { FileManager.default.fileExists(atPath: url.appending(path: $0 + ".md").path) }
        return try template(found ?? MeetingsSettings.summaryTemplate.defaultValue)
    }

    // Checked as a template before it is written, so a saved file always reads back.
    public func save(_ id: String, name: String, text: String) throws {
        let markdown = SummaryTemplate.markdown(name: name, text: text)
        _ = try SummaryTemplate(id: id, markdown: markdown)
        try refresh()
        let file = url.appending(path: id + ".md")
        try Data(markdown.utf8).write(to: file, options: .atomic)
        try AppPaths.makeOwnerOnly(file)
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: url.appending(path: id + ".md"))
    }

    // A file name from the name: lower case letters and digits joined by dashes, with a number added on a clash.
    public func newID(for name: String) -> String {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        let base = words.isEmpty ? "template" : words.joined(separator: "-")
        var id = base
        var number = 1
        while Self.builtInIDs.contains(id) || FileManager.default.fileExists(atPath: url.appending(path: id + ".md").path) {
            number += 1
            id = "\(base)-\(number)"
        }
        return id
    }

    private func read(_ file: URL) throws -> SummaryTemplate {
        try SummaryTemplate(id: file.deletingPathExtension().lastPathComponent, markdown: String(contentsOf: file, encoding: .utf8))
    }

    private func refresh() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: AppPaths.ownerOnly])
        let fingerprints = try shipped.load()
        var copied: [String: String] = [:]
        for (id, text) in builtIns {
            let file = url.appending(path: id + ".md")
            if let current = try? Data(contentsOf: file) {
                guard Self.fingerprint(current) == fingerprints[id], current != Data(text.utf8) else { continue }
            }
            try Data(text.utf8).write(to: file, options: .atomic)
            try AppPaths.makeOwnerOnly(file)
            copied[id] = Self.fingerprint(Data(text.utf8))
        }
        guard !copied.isEmpty else { return }
        try shipped.edit { $0.merge(copied) { _, new in new } }
        Log.count("summary-templates-copied", copied.count)
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
