import Foundation

public enum ModelJob: Sendable {
    case speech
    case cleanup
}

// Measured numbers only, one method per metric for a whole list (DESIGN.md, Metrics strip); a value nobody has
// measured that way stays nil and its bar is left out.
public struct ModelMetrics: Sendable, Equatable {
    // Speech: seconds for the 16.6 s English clip. Clean-up: median seconds per test input.
    public var speedSeconds: Double?
    // Speech: share of words right on the English set. Clean-up: share of test inputs with every fact kept.
    public var accuracy: Double?
    // Speech: peak while transcribing. Clean-up: held while loaded. Both above the footprint before loading.
    public var memoryBytes: Int64?
    public var diskBytes: Int64?

    public init(speedSeconds: Double? = nil, accuracy: Double? = nil, memoryBytes: Int64? = nil, diskBytes: Int64? = nil) {
        self.speedSeconds = speedSeconds
        self.accuracy = accuracy
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}

public struct CatalogueModel: Sendable, Equatable, Identifiable {
    // Speech: the model's folder in the model store. Clean-up: "org/name@revision".
    public let id: String
    public let name: String
    public let languages: String?
    public let isRecommended: Bool
    public let metrics: ModelMetrics
    public let licence: String?
    // What a meeting model does for a meeting, in a few plain words.
    public let purpose: String?
    // A meeting model's everyday name; name stays the technical one.
    public let plainName: String?

    public init(
        id: String, name: String, languages: String? = nil, isRecommended: Bool = false, metrics: ModelMetrics = ModelMetrics(),
        licence: String? = nil, purpose: String? = nil, plainName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.languages = languages
        self.isRecommended = isRecommended
        self.metrics = metrics
        self.licence = licence
        self.purpose = purpose
        self.plainName = plainName
    }

    // "25 European languages, on this Mac", or "On this Mac" when the languages are not known.
    public var summary: String {
        languages.map { "\($0), on this Mac" } ?? "On this Mac"
    }
}

// The models each settings list offers, recommended first. Numbers: the model bench of 19 Nov 2026 on an M4 Pro.
public enum ModelCatalogue {
    public static let speech = [
        speechEntry(
            .ultra, languages: "25 European languages",
            metrics: ModelMetrics(speedSeconds: 0.120, accuracy: 0.967, memoryBytes: 80_625_784, diskBytes: 642_560_000)
        ),
        speechEntry(
            .v3, languages: "25 European languages",
            metrics: ModelMetrics(speedSeconds: 0.120, accuracy: 0.956, memoryBytes: 71_909_520, diskBytes: 483_307_520)
        )
    ]

    public static let cleanup = [
        CatalogueModel(
            id: CleanupSettings.localModel.defaultValue,
            name: "Qwen3.5 2B",
            isRecommended: true,
            metrics: ModelMetrics(speedSeconds: 0.40, accuracy: 0.95, memoryBytes: 2_621_147_488, diskBytes: 2_689_744_896)
        ),
        CatalogueModel(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit@32f3e8ecf65426fc3306969496342d504bfa13f3",
            name: "Qwen3.5 4B",
            metrics: ModelMetrics(speedSeconds: 0.70, accuracy: 1, memoryBytes: 3_303_803_616, diskBytes: 3_061_157_888)
        ),
        CatalogueModel(
            id: "mlx-community/Qwen3.5-0.8B-8bit@87e768fbfa03994095f3d14527c80c5ae70c5758",
            name: "Qwen3.5 0.8B",
            languages: "English",
            metrics: ModelMetrics(speedSeconds: 0.19, accuracy: 0.95, memoryBytes: 1_365_198_000, diskBytes: 1_034_391_552)
        )
    ]

    // What a meeting needs besides the speech model. Disk: measured after a download on 22 Nov 2026.
    public static let meetings = [
        meetingEntry(.echoRemoval, "Echo removal", purpose: "Removes the call's echo from your microphone", diskBytes: 19_648_512),
        meetingEntry(.speechDetection, "Speech detection", purpose: "Finds speech for the echo check", diskBytes: 1_081_344),
        meetingEntry(.speakerSplit, "Speaker split", purpose: "Tells the speakers apart", diskBytes: 21_843_968)
    ]

    private static func meetingEntry(_ model: AudioModel, _ plainName: String, purpose: String, diskBytes: Int64?) -> CatalogueModel {
        CatalogueModel(
            id: model.folder, name: model.name, metrics: ModelMetrics(diskBytes: diskBytes), licence: model.licence, purpose: purpose,
            plainName: plainName
        )
    }

    private static func speechEntry(_ model: ParakeetModel, languages: String, metrics: ModelMetrics) -> CatalogueModel {
        CatalogueModel(
            id: model.folder,
            name: model.name,
            languages: languages,
            isRecommended: model == .recommended,
            metrics: metrics
        )
    }
}
