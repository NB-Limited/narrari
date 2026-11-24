import Foundation
import NarrariKit
import Testing

@MainActor
struct AppDirectoryTests {
    private let folder = TemporaryFolder()

    private func makeApp(_ name: String, identifier: String) throws {
        let contents = folder.url.appending(path: "\(name).app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL"], format: .xml, options: 0
        )
        try info.write(to: contents.appending(path: "Info.plist"))
    }

    @Test func picker_lists_each_app_in_the_folders_once_by_name() async throws {
        try makeApp("Zettel", identifier: "com.example.zettel")
        try makeApp("Notes Pro", identifier: "com.example.notes")
        try Data().write(to: folder.url.appending(path: "readme.txt"))

        let listed = await AppDirectory(folders: [folder.url, folder.url]).installedAndRunning()
            .filter { $0.bundleIdentifier.hasPrefix("com.example.") }

        #expect(listed.map(\.name) == ["Notes Pro", "Zettel"])
        #expect(listed.map(\.bundleIdentifier) == ["com.example.notes", "com.example.zettel"])
    }
}
