import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers

// Transcribes one file at a time into a history entry, listed in the library while it runs.
@MainActor
@Observable
public final class FileJob {
    public struct Running: Equatable {
        public let id: UUID
        public var work = WorkState.working(.transcribing, progress: 0)
    }

    public struct Ended: Sendable, Equatable {
        public let id: UUID
        public let fileName: String
        public let work: WorkState
    }

    public enum Notice: Equatable {
        case failed(fileName: String, Problem)
        case busy
    }

    public static let fileTypes: [UTType] = [.audio, .movie]
    public static let busyMessage = "A file is already being transcribed. Wait for it, or cancel it first."
    static let modelNotReady = Problem("file.model-not-ready", "The speech model is still loading. Try again when the menu says Ready.")

    public private(set) var running: Running?
    public private(set) var notice: Notice?
    // Every file that was saved or failed, oldest first; a cancelled one is left out.
    public private(set) var ended: [Ended] = []

    @ObservationIgnored private let library: HistoryLibrary
    @ObservationIgnored private let retranscription: Retranscription
    @ObservationIgnored private let isModelReady: @MainActor () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?

    public var isWorking: Bool { running != nil }

    public init(
        library: HistoryLibrary,
        retranscription: Retranscription,
        isModelReady: @escaping @MainActor () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.retranscription = retranscription
        self.isModelReady = isModelReady
        self.now = now
    }

    // Only a file on this Mac of a type the job reads; a web link or a document never reaches the decoder.
    public static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        return type.map { type in fileTypes.contains { type.conforms(to: $0) } } ?? false
    }

    // Says so when a file is already running, so a new one is not picked in vain.
    public func canStart() -> Bool {
        if isWorking { notice = .busy }
        return !isWorking
    }

    // What a drop does: the first supported file starts; with none, the first one says why.
    public func offer(_ urls: [URL]) {
        guard let url = urls.first(where: Self.isSupported) ?? urls.first else { return }
        start(url)
    }

    public func start(_ url: URL) {
        guard !isWorking else {
            notice = .busy
            return
        }
        notice = nil
        let fileName = url.lastPathComponent
        guard Self.isSupported(url) else {
            notice = .failed(fileName: fileName, AudioFileError.unreadable.problem)
            return
        }
        guard isModelReady() else {
            notice = .failed(fileName: fileName, Self.modelNotReady)
            return
        }
        Log.event("file-job-start")
        let id = UUID()
        var entry = HistoryEntry(id: id, startedAt: now(), audioFile: HistoryEntry.audioFileName(for: id), outcome: .kept)
        entry.file = fileName
        running = Running(id: id)
        library.show(pending: entry)
        let steps = Mutex(FileTranscription.Steps())
        task = Task { [retranscription] in
            do {
                _ = try await retranscription.run(file: url, as: entry) { fraction in
                    guard steps.withLock({ $0.admit(fraction) }) else { return }
                    Task { @MainActor in self.report(fraction, for: id) }
                }
                Log.event("file-job-done")
                await finish(id, notice: nil, saved: true)
                ended.append(Ended(id: id, fileName: fileName, work: .done))
            } catch is CancellationError {
                Log.event("file-job-cancelled")
            } catch {
                Log.failure("file-job", error: error)
                let problem = error.problem(or: TranscriberError.transcriptionFailed.problem)
                await finish(id, notice: .failed(fileName: fileName, problem), saved: false)
                ended.append(Ended(id: id, fileName: fileName, work: .failed(problem)))
            }
        }
    }

    // The placeholder goes at once; the run stops at its next step and removes what it wrote.
    public func cancel() {
        guard isWorking else { return }
        task?.cancel()
        task = nil
        running = nil
        if notice == .busy { notice = nil }
        library.endPending()
    }

    public func dismissNotice() {
        notice = nil
    }

    private func finish(_ id: UUID, notice: Notice?, saved: Bool) async {
        // A saved file is read back before its placeholder goes, so the list never drops it in between.
        if saved { await library.refresh() }
        // Cancelled too late to stop the save: the entry is whole, so it stays listed.
        guard running?.id == id else { return }
        task = nil
        running = nil
        self.notice = notice
        library.endPending()
    }

    private func report(_ fraction: Double, for id: UUID) {
        guard running?.id == id else { return }
        running?.work = .working(.transcribing, progress: fraction)
    }
}
