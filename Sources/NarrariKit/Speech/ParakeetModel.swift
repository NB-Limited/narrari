import FluidAudio
import Foundation

// The speech models that run through the one Parakeet path; they differ only in the version FluidAudio loads.
// Stored by folder, so a folder this build does not list, such as one a newer build wrote, reads as the default.
public enum ParakeetModel: CaseIterable, Sendable, RawRepresentable {
    case ultra
    case v3

    public static let recommended = ParakeetModel.ultra

    public init?(rawValue: String) {
        guard let model = Self.allCases.first(where: { $0.folder == rawValue }) else { return nil }
        self = model
    }

    public var rawValue: String { folder }

    var version: AsrModelVersion {
        switch self {
        case .ultra: .ultra
        case .v3: .v3
        }
    }

    public var folder: String { AsrModels.defaultCacheDirectory(for: version).lastPathComponent }

    public var name: String {
        switch self {
        case .ultra: "Parakeet Ultra"
        case .v3: "Parakeet v3"
        }
    }
}
