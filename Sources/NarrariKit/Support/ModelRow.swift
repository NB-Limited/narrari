import Foundation

// What one model row in settings says and offers: one state, its radio, at most one action, and whether its files can be deleted.
public struct ModelRow: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case notDownloaded
        case downloaded
        case inUse
        // Downloading, getting ready from files on this Mac, or failed.
        case work(WorkState)
    }

    public enum Action: Sendable, Equatable {
        case download
        case cancel
        case retry
    }

    public let status: Status
    private let isChosen: Bool
    private let canUse: Bool
    private let isOnDisk: Bool

    // Files on this Mac decide what a row is, since a state just after a switch can still describe the previous model.
    // The chosen model stays in use while it loads or after it was let go for being idle.
    public init(state: ModelState, isChosen: Bool, bytesOnDisk: Int64, canUse: Bool = true) {
        self.isChosen = isChosen
        self.canUse = canUse
        isOnDisk = bytesOnDisk > 0
        let isOnDisk = isOnDisk
        status = switch state {
        case .preparing(let fraction, false) where !isOnDisk: .work(.working(.downloading, progress: fraction))
        case .preparing, .failed: .work(state.work)
        case .ready, .missing: !isOnDisk ? .notDownloaded : isChosen ? .inUse : .downloaded
        }
    }

    public var work: WorkState {
        if case .work(let work) = status { return work }
        return .idle
    }

    public var action: Action? {
        switch status {
        case .notDownloaded: canUse ? .download : nil
        case .work(.failed): .retry
        case .work: isGettingReady ? nil : .cancel
        case .downloaded, .inUse: nil
        }
    }

    // The chosen model keeps its filled radio while it downloads, gets ready or fails; only a downloaded model can be chosen.
    public var mark: ChoiceMark {
        switch status {
        case .inUse: .chosen
        case .work: isChosen ? .chosen : .unavailable
        case .downloaded: canUse ? .available : .unavailable
        case .notDownloaded: .unavailable
        }
    }

    public var isInUse: Bool { status == .inUse }

    public var isGettingReady: Bool { work.activity == .gettingReady }

    public var canDelete: Bool {
        status == .downloaded || status == .inUse || isGettingReady
    }

    public var group: ModelGroup {
        if !canUse { return .noLongerUsed }
        switch status {
        case .downloaded, .inUse: return .onThisMac
        case .work: return isGettingReady || (work.problem != nil && isOnDisk) ? .onThisMac : .toDownload
        case .notDownloaded: return .toDownload
        }
    }

    // "Downloading, 46%" with its share for the bar; nothing while it gets ready, so the row keeps its size.
    public var progressLine: String? {
        work.activity == .downloading ? work.label : nil
    }

    public var progress: Double? {
        work.activity == .downloading ? work.progress ?? 0 : nil
    }

    public var failure: String? { work.problem?.besideRetry }
}

// Models on this Mac first, then those to download, then files the catalogue no longer lists.
public enum ModelGroup: Sendable, CaseIterable {
    case onThisMac
    case toDownload
    case noLongerUsed

    public var heading: String? {
        switch self {
        case .onThisMac: nil
        case .toDownload: "Available to download"
        case .noLongerUsed: "No longer used"
        }
    }

    // Each group keeps the list's order; empty groups are left out.
    public static func split(_ models: [CatalogueModel], row: (CatalogueModel) -> ModelRow) -> [(group: ModelGroup, models: [CatalogueModel])] {
        let grouped = Dictionary(grouping: models) { row($0).group }
        return allCases.compactMap { group in grouped[group].map { (group, $0) } }
    }
}
