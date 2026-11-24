import Foundation

public enum MeetingError: Error, Equatable {
    case notFound
}

// One folder of plain files per meeting, at <root>/<folder>/<yyyy-MM-dd HHmm> <title>/.
public actor MeetingStore {
    public typealias Trash = @Sendable (URL) throws -> Void

    public enum Document: String, Sendable {
        case notes = "notes.md"
        case summary = "summary.md"
        case previousSummary = "summary.previous.md"
    }

    // The cleaned microphone track is for transcription only; the player and the files a person keeps use mic.caf.
    public enum Audio: String, CaseIterable, Sendable {
        case microphone = "mic.caf"
        case system = "system.caf"
        case cleanedMicrophone = "mic.clean.caf"
    }

    public static let moveToTrash: Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public nonisolated let root: URL
    // Once after each change to a meeting.json or a meeting's folder, for the one list that follows them.
    public nonisolated let changes: AsyncStream<Void>
    nonisolated let calendar: Calendar
    private let trash: Trash
    private let changed: AsyncStream<Void>.Continuation
    private var folders: [UUID: URL] = [:]

    private static let meetingFile = "meeting.json"
    private static let transcriptFile = "transcript.json"
    private static let transcriptText = "transcript.md"
    private static let wordsFile = "words.json"
    private static let voicesFile = "voices.json"
    private static let importFolder = "Imported"
    private static let recordingsFolder = "Recordings"
    private static let titleLimit = 80
    private static let stampFormat: Date.FormatString = """
        \(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)
        """

    public init(root: URL, calendar: Calendar = HistoryStore.localCalendar, trash: @escaping Trash) {
        self.root = root
        self.calendar = calendar
        self.trash = trash
        (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // A meeting with a call app goes in the folder named after it; appName is that app's name, or empty.
    @discardableResult
    public func create(_ meeting: Meeting, appName: String) throws -> URL {
        let parentName = meeting.source == .import ? Self.importFolder : Self.folderSafe(appName)
        let parent = root.appending(path: parentName.isEmpty ? Self.recordingsFolder : parentName, directoryHint: .isDirectory)
        let folder = freeFolder(for: meeting, in: parent, current: nil)
        try makeFolder(folder)
        try write(meeting, in: folder)
        folders[meeting.id] = folder
        changed.yield()
        return folder
    }

    // While the meeting records its folder keeps its name; the title it was given is applied when it stops.
    public func save(_ meeting: Meeting) throws {
        let (folder, stored) = try locate(meeting.id)
        try write(meeting, in: folder)
        changed.yield()
        if stored.speakers != meeting.speakers { try writeTranscriptText(in: folder, speakers: meeting.speakers) }
        guard !meeting.state.isTakingAudio else { return }
        let target = freeFolder(for: meeting, in: folder.deletingLastPathComponent(), current: folder)
        guard target.lastPathComponent != folder.lastPathComponent else { return }
        try FileManager.default.moveItem(at: folder, to: target)
        folders[meeting.id] = target
    }

    // Newest first. A folder whose meeting.json can't be read is listed apart, whatever the date, and never changed.
    public func meetings(since: Date? = nil) throws -> (meetings: [Meeting], unreadable: [URL]) {
        let listed = try list()
        return (listed.meetings.map(\.meeting).filter { meeting in since.map { meeting.startedAt >= $0 } ?? true }, listed.unreadable)
    }

    // The same, with the name of the folder each meeting sits in.
    public func list() throws -> (meetings: [(meeting: Meeting, folder: String)], unreadable: [URL]) {
        let scan = try scan()
        let meetings = scan.readable.map { (meeting: $0.meeting, folder: $0.folder.deletingLastPathComponent().lastPathComponent) }
        return (meetings.sorted { $0.meeting.startedAt > $1.meeting.startedAt }, scan.unreadable.sorted { $0.path < $1.path })
    }

    public func folder(of id: UUID) throws -> URL {
        try locate(id).folder
    }

    // Into another folder under the root, made when it is new; the folder left empty goes.
    public func move(_ id: UUID, toFolder name: String) throws {
        let (folder, meeting) = try locate(id)
        let name = Self.folderSafe(name)
        let parent = root.appending(path: name, directoryHint: .isDirectory)
        let previous = folder.deletingLastPathComponent()
        guard !name.isEmpty, parent.lastPathComponent != previous.lastPathComponent else { return }
        try makeFolder(parent)
        let target = freeFolder(for: meeting, in: parent, current: nil)
        try FileManager.default.moveItem(at: folder, to: target)
        folders[id] = target
        if try subfolders(of: previous).isEmpty, try FileManager.default.contentsOfDirectory(atPath: previous.path).isEmpty {
            try FileManager.default.removeItem(at: previous)
        }
        changed.yield()
    }

    public func meeting(_ id: UUID) throws -> Meeting {
        try locate(id).meeting
    }

    public func transcript(of id: UUID) throws -> [TranscriptSegment] {
        try JSONFile(try locate(id).folder.appending(path: Self.transcriptFile), empty: []).load()
    }

    public func write(_ segments: [TranscriptSegment], of id: UUID) throws {
        let (folder, meeting) = try locate(id)
        try JSONFile<[TranscriptSegment]>(folder.appending(path: Self.transcriptFile), empty: []).edit { $0 = segments }
        try writeText(TranscriptSegment.markdown(segments, speakers: meeting.speakers), to: folder.appending(path: Self.transcriptText))
    }

    // Nil for a meeting transcribed before word timings were kept.
    public func words(of id: UUID) throws -> MeetingTranscript.Words? {
        try JSONFile<MeetingTranscript.Words?>(try locate(id).folder.appending(path: Self.wordsFile), empty: nil).load()
    }

    public func write(_ words: MeetingTranscript.Words, of id: UUID) throws {
        try JSONFile<MeetingTranscript.Words?>(try locate(id).folder.appending(path: Self.wordsFile), empty: nil).edit { $0 = words }
    }

    // Each speaker's voice print from this meeting, by speaker id, so a rename can teach it to a person. Numbers only.
    public func voices(of id: UUID) throws -> [String: [Float]] {
        try JSONFile(try locate(id).folder.appending(path: Self.voicesFile), empty: [:]).load()
    }

    public func write(voices: [String: [Float]], of id: UUID) throws {
        try JSONFile<[String: [Float]]>(try locate(id).folder.appending(path: Self.voicesFile), empty: [:]).edit { $0 = voices }
    }

    // Where the track is or would be; it may not exist, such as system.caf of a meeting recorded from the microphone alone.
    public func audio(_ track: Audio, of id: UUID) throws -> URL {
        try locate(id).folder.appending(path: track.rawValue)
    }

    public func text(_ document: Document, of id: UUID) throws -> String {
        let url = try locate(id).folder.appending(path: document.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ text: String, to document: Document, of id: UUID) throws {
        try writeText(text, to: try locate(id).folder.appending(path: document.rawValue))
    }

    // Read and saved in one go, so two changes made at once never undo each other.
    public func update(_ id: UUID, _ change: @Sendable (inout Meeting) -> Void) throws {
        var meeting = try locate(id).meeting
        change(&meeting)
        try save(meeting)
    }

    // At launch: a cut-off import is a partial copy, so it goes; a cut-off recording keeps what its tracks hold.
    public func recover() throws {
        for (folder, meeting) in try scan().readable where meeting.state == .importing {
            try trash(folder)
            folders[meeting.id] = nil
            changed.yield()
            Log.event("meeting-import-abandoned")
        }
        for (folder, meeting) in try scan().readable where meeting.state == .recording {
            var recovered = meeting
            recovered.state = .recovered
            recovered.durationMs = Self.recordedMilliseconds(in: folder)
            try save(recovered)
            Log.event("meeting-recovered")
        }
    }

    public func delete(_ id: UUID) throws {
        try trash(try locate(id).folder)
        folders[id] = nil
        changed.yield()
    }

    // Text always stays, and so does the audio of a pinned meeting, one still taking it in, or one whose steps still need it.
    func removeAudio(startedBefore cutoff: Date) throws {
        for audio in try audioFiles(startedBefore: cutoff) {
            try audio.forEach(FileManager.default.removeItem(at:))
            changed.yield()
            Log.event("meeting-audio-removed")
        }
    }

    // How many meetings removeAudio would take audio from.
    func meetingsWithAudio(startedBefore cutoff: Date) throws -> Int {
        try audioFiles(startedBefore: cutoff).count
    }

    private func audioFiles(startedBefore cutoff: Date) throws -> [[URL]] {
        try scan().readable
            .filter { $0.meeting.startedAt < cutoff && !$0.meeting.pinned && !$0.meeting.state.isTakingAudio && !$0.meeting.steps.needAudio }
            .map { folder, _ in Audio.allCases.map { folder.appending(path: $0.rawValue) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
            .filter { !$0.isEmpty }
    }

    public struct Usage: Sendable, Equatable {
        public let meetings: Int
        public let bytes: Int64
    }

    public func usage() throws -> Usage {
        let count = try scan().readable.count
        var bytes: Int64 = 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let url = files?.nextObject() as? URL {
            bytes += Int64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }
        return Usage(meetings: count, bytes: bytes)
    }

    private static func recordedMilliseconds(in folder: URL) -> Int {
        let samples = [Audio.microphone, .system].map { folder.appending(path: $0.rawValue) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { track -> Int? in
                do {
                    return try TrackReader(track).sampleCount
                } catch {
                    Log.failure("meeting-recover-length", error: error)
                    return nil
                }
            }
        return Int(Double(samples.max() ?? 0) / SpeechAudio.sampleRate * 1000)
    }

    // Calendar titles and app names become folder names, so only letters, digits, space, dash and dot are kept.
    private static func folderSafe(_ text: String) -> String {
        let kept = text.compactMap { (character: Character) -> Character? in
            if character.isWhitespace { return " " }
            return character.isLetter || character.isNumber || "-.".contains(character) ? character : nil
        }
        let spaced = kept.split(separator: " ").map { String($0) }.joined(separator: " ")
        return String(spaced.prefix(titleLimit)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    // The folder name the meeting should have, with " 2", " 3" added on a clash with another meeting's folder.
    private func freeFolder(for meeting: Meeting, in parent: URL, current: URL?) -> URL {
        let stamp = meeting.startedAt.formatted(stampStyle)
        let title = Self.folderSafe(meeting.title)
        let base = title.isEmpty ? stamp : "\(stamp) \(title)"
        var name = base
        var number = 1
        while true {
            let url = parent.appending(path: name, directoryHint: .isDirectory)
            // The disk ignores case, so a title that only changes case would clash with its own folder; it keeps the old one.
            if let current, name.caseInsensitiveCompare(current.lastPathComponent) == .orderedSame { return current }
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
            name = "\(base) \(number)"
        }
    }

    private func locate(_ id: UUID) throws -> (folder: URL, meeting: Meeting) {
        if let folder = folders[id], let meeting = try? read(folder), meeting.id == id { return (folder, meeting) }
        guard let found = try scan().readable.first(where: { $0.meeting.id == id }) else { throw MeetingError.notFound }
        return found
    }

    private func scan() throws -> (readable: [(folder: URL, meeting: Meeting)], unreadable: [URL]) {
        var readable: [(folder: URL, meeting: Meeting)] = []
        var unreadable: [URL] = []
        for parent in try subfolders(of: root) {
            for folder in try subfolders(of: parent) {
                if let meeting = try? read(folder) {
                    readable.append((folder, meeting))
                } else {
                    unreadable.append(folder)
                }
            }
        }
        folders = Dictionary(readable.map { ($0.meeting.id, $0.folder) }) { first, _ in first }
        return (readable, unreadable)
    }

    private func read(_ folder: URL) throws -> Meeting {
        try Meeting(json: Data(contentsOf: folder.appending(path: Self.meetingFile)))
    }

    // Merged into the file on disk, so keys written by a later version stay.
    private func write(_ meeting: Meeting, in folder: URL) throws {
        let fields = try meeting.fields
        try JSONFile<[String: JSONValue]>(folder.appending(path: Self.meetingFile), empty: [:]).edit { stored in
            stored.merge(fields) { _, new in new }
        }
    }

    private func writeTranscriptText(in folder: URL, speakers: [Meeting.Speaker]) throws {
        let json = folder.appending(path: Self.transcriptFile)
        guard FileManager.default.fileExists(atPath: json.path) else { return }
        let segments = try JSONFile<[TranscriptSegment]>(json, empty: []).load()
        try writeText(TranscriptSegment.markdown(segments, speakers: speakers), to: folder.appending(path: Self.transcriptText))
    }

    private func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try AppPaths.makeOwnerOnly(url)
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: AppPaths.ownerOnly]
        )
    }

    private func subfolders(of url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private var stampStyle: Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(
            format: Self.stampFormat, locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone, calendar: calendar
        )
    }
}
