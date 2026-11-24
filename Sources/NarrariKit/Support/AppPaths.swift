import Foundation

public enum AppPaths {
    public static let applicationSupport: URL = ownerOnlyFolder(
        URL.applicationSupportDirectory.appending(path: "Narrari", directoryHint: .isDirectory)
    )

    public static let models: URL = directory(
        applicationSupport.appending(path: "Models", directoryHint: .isDirectory)
    )

    public static let history: URL = directory(
        applicationSupport.appending(path: "History", directoryHint: .isDirectory), permissions: ownerOnly
    )

    public static let meetings: URL = directory(
        applicationSupport.appending(path: "Meetings", directoryHint: .isDirectory), permissions: ownerOnly
    )

    // History and meetings hold recorded audio and text, so only the owner may list or open them.
    static let ownerOnly = 0o700
    static let ownerOnlyFile = 0o600

    // For a file a system writer creates with the default permissions, such as an atomic write or an audio file.
    static func makeOwnerOnly(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: ownerOnlyFile], ofItemAtPath: file.path)
    }

    // Prompts, the dictionary and modes sit here. Earlier versions left them readable by all, so the files
    // already in it are narrowed too, by their permissions alone; nothing in them is read.
    public static func ownerOnlyFolder(_ url: URL) -> URL {
        let folder = directory(url, permissions: ownerOnly)
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for item in items where (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            do {
                try makeOwnerOnly(item)
            } catch {
                Log.failure("owner-only-file", error: error)
            }
        }
        return folder
    }

    private static func directory(_ url: URL, permissions: Int? = nil) -> URL {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: permissions.map { [.posixPermissions: $0] }
            )
            if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        } catch {
            Log.failure("create-directory", error: error)
        }
        return url
    }
}
