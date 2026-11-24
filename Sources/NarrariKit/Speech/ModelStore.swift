import FluidAudio
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

    // A download cut off part way leaves its folder holding `.partial` files, so the folder alone is no model.
    public func isPresent(named name: String) -> Bool {
        let folder = directory(named: name)
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            if file.pathExtension == "partial" { return false }
        }
        return true
    }

    // Every file the speech model loads is there whole, by the list FluidAudio downloads; a cut-off download downloads again.
    public func isPresent(_ model: ParakeetModel) -> Bool {
        AsrModels.modelsExist(at: directory(named: model.folder), version: model.version)
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
