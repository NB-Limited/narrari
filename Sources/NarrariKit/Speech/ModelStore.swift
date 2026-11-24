import Foundation

public struct ModelStore: Sendable {
    public static let shared = ModelStore(root: AppPaths.models)

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(named name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }

    public func isPresent(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(named: name).path)
    }

    public func bytesOnDisk(named name: String) throws -> Int64 {
        try Self.bytes(in: directory(named: name))
    }

    public static func bytes(in directory: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard FileManager.default.fileExists(atPath: directory.path),
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    public func delete(named name: String) throws {
        let directory = directory(named: name)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
