import Foundation
import NarrariKit
import Testing

struct AppPathsTests {
    private let folder = TemporaryFolder()

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func an_existing_install_becomes_owner_only_on_launch() throws {
        let narrari = folder.url.appending(path: "Narrari", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: narrari, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let dictionary = narrari.appending(path: "dictionary.json")
        #expect(FileManager.default.createFile(atPath: dictionary.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644]))

        _ = AppPaths.ownerOnlyFolder(narrari)

        #expect(try permissions(narrari) == 0o700)
        #expect(try permissions(dictionary) == 0o600)
        #expect(try Data(contentsOf: dictionary) == Data("{}".utf8))
    }
}
