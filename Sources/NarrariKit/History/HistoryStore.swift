import Foundation

public enum HistoryError: Error, Equatable {
    case entryGone
}

public actor HistoryStore {
    public nonisolated let root: URL
    private let calendar: Calendar

    private static let newline = UInt8(ascii: "\n")
    private static let audioExtension = "caf"
    private static let dayFileExtension = "jsonl"
    private static let dayFormat: Date.FormatString = "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)"

    public static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    public init(root: URL, calendar: Calendar = HistoryStore.localCalendar) {
        self.root = root
        self.calendar = calendar
    }

    public nonisolated func audioURL(for id: UUID) -> URL {
        root.appending(path: HistoryEntry.audioFileName(for: id))
    }

    public func append(_ entry: HistoryEntry) throws {
        var line = try entry.jsonLine()
        line.append(Self.newline)
        let url = dayFileURL(for: entry.startedAt)
        let manager = FileManager.default
        try makeRoot()
        if !manager.fileExists(atPath: url.path) {
            // The file holds dictated text, so only the owner may read it.
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: AppPaths.ownerOnlyFile]) else {
                throw CocoaError.error(.fileWriteUnknown, url: url)
            }
        }
        let handle = try FileHandle(forUpdating: url)
        do {
            // A crash can leave a last line without its newline; start a fresh line so only that one line is lost.
            if try endsMidLine(handle) { line.insert(Self.newline, at: 0) }
            try handle.write(contentsOf: line)
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    // Where new audio for this entry is written, with the folder made if it has gone.
    public func audioDestination(for id: UUID) throws -> URL {
        try makeRoot()
        return audioURL(for: id)
    }

    public func removeAudio(for id: UUID) throws {
        let url = audioURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func entries() throws -> (entries: [HistoryEntry], skipped: Int) {
        let scan = try scan()
        let live = scan.latest.values.filter { !$0.isDeleted }
        return (live.sorted { $0.startedAt > $1.startedAt }, scan.skipped)
    }

    // Appends only while the entry's newest line exists and is not a deletion, so a late result never revives it.
    public func update(_ entry: HistoryEntry) throws {
        let url = dayFileURL(for: entry.startedAt)
        let lines = FileManager.default.fileExists(atPath: url.path) ? try parse(url).entries : []
        guard let latest = lines.last(where: { $0.id == entry.id }), !latest.isDeleted else { throw HistoryError.entryGone }
        try append(entry)
    }

    public func delete(_ entry: HistoryEntry) throws {
        var tombstone = entry
        tombstone.deleted = true
        try append(tombstone)
        try removeAudio(for: entry.id)
    }

    public func recover() throws {
        let scan = try scan()
        for entry in scan.latest.values where !entry.isFinished && !entry.isDeleted {
            var failed = entry
            failed.outcome = .failed
            try append(failed)
            Log.event("history-entry-recovered")
        }
        for audio in try audioFiles() where !scan.audioNames.contains(audio.lastPathComponent) {
            guard
                let id = UUID(uuidString: audio.deletingPathExtension().lastPathComponent),
                let created = try audio.resourceValues(forKeys: [.creationDateKey]).creationDate
            else { continue }
            try append(
                HistoryEntry(id: id, startedAt: created, audioFile: audio.lastPathComponent, outcome: .failed)
            )
            Log.event("history-audio-adopted")
        }
    }

    // Dictations in `kept` survive with their audio, such as one still recording across midnight.
    public func removeDays(olderThan days: Int, now: Date, keeping kept: Set<UUID> = []) throws {
        let today = calendar.startOfDay(for: now)
        for (url, day) in try dayFiles() {
            guard let age = calendar.dateComponents([.day], from: day, to: today).day, age > days else { continue }
            for entry in try parse(url).entries where !kept.contains(entry.id) {
                guard let audio = audioURL(named: entry.audioFile), FileManager.default.fileExists(atPath: audio.path) else { continue }
                try FileManager.default.removeItem(at: audio)
            }
            try remove(dayFile: url, keeping: kept)
            Log.event("history-day-removed")
        }
    }

    public struct Usage: Sendable, Equatable {
        public let dictations: Int
        public let bytes: Int64

        public init(dictations: Int, bytes: Int64) {
            self.dictations = dictations
            self.bytes = bytes
        }
    }

    public func usage() throws -> Usage {
        let count = try entries().entries.filter { $0.isFinished }.count
        var bytes: Int64 = 0
        for url in try contents() {
            bytes += Int64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }
        return Usage(dictations: count, bytes: bytes)
    }

    // What retention at this many days would remove, counted the way removeDays removes: by whole day files.
    public func dictations(olderThan days: Int, now: Date) throws -> Int {
        let today = calendar.startOfDay(for: now)
        var ids = Set<UUID>()
        for (url, day) in try dayFiles() {
            guard let age = calendar.dateComponents([.day], from: day, to: today).day, age > days else { continue }
            ids.formUnion(try parse(url).entries.filter { !$0.isDeleted && $0.isFinished }.map(\.id))
        }
        return ids.count
    }

    public func deleteAll(keeping kept: Set<UUID> = []) throws {
        let keptAudio = Set(kept.map(HistoryEntry.audioFileName(for:)))
        for url in try contents() {
            switch url.pathExtension {
            case Self.dayFileExtension: try remove(dayFile: url, keeping: kept)
            case Self.audioExtension where !keptAudio.contains(url.lastPathComponent): try FileManager.default.removeItem(at: url)
            default: break
            }
        }
        Log.event("history-deleted-all")
    }

    // Removes a day file, or rewrites it in one step down to the lines of the dictations kept.
    private func remove(dayFile url: URL, keeping kept: Set<UUID>) throws {
        let lines = kept.isEmpty ? [] : try Data(contentsOf: url).split(separator: Self.newline).filter { line in
            (try? HistoryEntry(jsonLine: Data(line))).map { kept.contains($0.id) } ?? false
        }
        guard !lines.isEmpty else { return try FileManager.default.removeItem(at: url) }
        var data = Data(lines.joined(separator: [Self.newline]))
        data.append(Self.newline)
        let replacement = root.appending(path: ".\(UUID().uuidString).tmp")
        let isWritten = FileManager.default.createFile(
            atPath: replacement.path, contents: data, attributes: [.posixPermissions: AppPaths.ownerOnlyFile]
        )
        guard isWritten else {
            throw CocoaError.error(.fileWriteUnknown, url: replacement)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
    }

    private struct Scan {
        var latest: [UUID: HistoryEntry] = [:]
        var audioNames: Set<String> = []
        var skipped = 0
    }

    private func scan() throws -> Scan {
        var scan = Scan()
        for (url, _) in try dayFiles() {
            let parsed = try parse(url)
            scan.skipped += parsed.skipped
            for entry in parsed.entries {
                scan.latest[entry.id] = entry
                scan.audioNames.insert(entry.audioFile)
            }
        }
        return scan
    }

    private func parse(_ url: URL) throws -> (entries: [HistoryEntry], skipped: Int) {
        var entries: [HistoryEntry] = []
        var skipped = 0
        for line in try Data(contentsOf: url).split(separator: Self.newline) {
            if let entry = try? HistoryEntry(jsonLine: Data(line)) {
                entries.append(entry)
            } else {
                skipped += 1
            }
        }
        return (entries, skipped)
    }

    private func makeRoot() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: AppPaths.ownerOnly]
        )
    }

    private func endsMidLine(_ handle: FileHandle) throws -> Bool {
        let end = try handle.seekToEnd()
        guard end > 0 else { return false }
        try handle.seek(toOffset: end - 1)
        return try handle.read(upToCount: 1) != Data([Self.newline])
    }

    private func dayFiles() throws -> [(url: URL, day: Date)] {
        try contents().compactMap { url in
            guard url.pathExtension == Self.dayFileExtension,
                  let day = try? Date(url.deletingPathExtension().lastPathComponent, strategy: dayParser)
            else { return nil }
            return (url, day)
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private func audioFiles() throws -> [URL] {
        try contents().filter { $0.pathExtension == Self.audioExtension }
    }

    private func contents() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    private func audioURL(named name: String) -> URL? {
        // Names come from a file on disk, so anything that is not a plain audio file name is ignored.
        guard name.hasSuffix(".\(Self.audioExtension)"), !name.contains("/") else { return nil }
        return root.appending(path: name)
    }

    private func dayFileURL(for date: Date) -> URL {
        root.appending(path: date.formatted(dayStyle)).appendingPathExtension(Self.dayFileExtension)
    }

    private var dayStyle: Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(
            format: Self.dayFormat, locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone, calendar: calendar
        )
    }

    private var dayParser: Date.ParseStrategy {
        Date.ParseStrategy(
            format: Self.dayFormat, locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone, calendar: calendar
        )
    }
}
