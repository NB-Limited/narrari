@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum AudioModelError: Error, Equatable {
    case notDownloaded
}

// The small models a meeting uses besides speech: speech detection, which the echo check reads, echo removal and the speaker split.
// Each sits in its own folder in the model store, named as FluidAudio names it.
public enum AudioModel: CaseIterable, Sendable {
    case speechDetection
    case echoRemoval
    case speakerSplit

    static let echoRemovalConfig = LocalVqeConfig(variant: .v13, chunk: .batch256ms, computeUnits: .cpuOnly)

    public var name: String {
        switch self {
        case .speechDetection: "Silero VAD"
        case .echoRemoval: "LocalVQE v1.3"
        case .speakerSplit: "pyannote community-1"
        }
    }

    public var licence: String {
        switch self {
        case .speechDetection: "MIT"
        case .echoRemoval: "Apache-2.0"
        case .speakerSplit: "CC-BY-4.0"
        }
    }

    public var folder: String { repo.folderName }

    // A model not on disk is never fetched here; the step that needs it waits while MeetingModels downloads it.
    func load(from store: ModelStore) async throws -> MLModel {
        guard store.isPresent(named: folder) else { throw AudioModelError.notDownloaded }
        return try await fetch(into: store, progress: nil)
    }

    // Fetched beside the store and moved in whole, so a step never finds half a model and reads it as present.
    public func download(into store: ModelStore, progress: @escaping @Sendable (Double) -> Void) async throws {
        let staging = URL.temporaryDirectory.appending(path: "narrari-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try await fetch(into: staging) { progress($0.fractionCompleted) }
        let target = store.directory(named: folder)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging.appending(path: folder, directoryHint: .isDirectory), to: target)
    }

    private func fetch(into store: ModelStore, progress: ProgressHandler?) async throws -> MLModel {
        try await fetch(into: store.directory(named: folder).deletingLastPathComponent(), progress: progress)
    }

    private func fetch(into root: URL, progress: ProgressHandler?) async throws -> MLModel {
        let models = try await FluidAudio::ModelHub.loadModels(
            repo, modelNames: [file], directory: root, computeUnits: computeUnits, variant: variant, progressHandler: progress
        )
        guard let model = models[file] else { throw AudioModelError.notDownloaded }
        return model
    }

    private var repo: Repo {
        switch self {
        case .speechDetection: .vad
        case .echoRemoval: .localVqe
        case .speakerSplit: .diarizer
        }
    }

    private var file: String {
        switch self {
        case .speechDetection: ModelNames.VAD.sileroVadFile
        case .echoRemoval: ModelNames.LocalVQE.modelFile(variant: Self.echoRemovalConfig.variant, chunk: Self.echoRemovalConfig.chunk)
        case .speakerSplit: ModelNames.OfflineDiarizer.segmentationPath
        }
    }

    private var variant: String? {
        switch self {
        case .speechDetection: nil
        case .echoRemoval: ModelNames.LocalVQE.variantKey(variant: Self.echoRemovalConfig.variant, chunk: Self.echoRemovalConfig.chunk)
        case .speakerSplit: SpeakerSplit.modelVariant
        }
    }

    private var computeUnits: MLComputeUnits {
        switch self {
        case .speechDetection: VadConfig.default.computeUnits
        case .echoRemoval: Self.echoRemovalConfig.computeUnits
        case .speakerSplit: .all
        }
    }
}
