import Foundation

// What meeting.json holds. No field at the top is optional, because a rewrite merges into the file
// to keep keys it does not know, and a nil would leave the old value standing.
public struct Meeting: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case call
        case manual
        case `import`
    }

    public enum State: String, Codable, Sendable {
        case recording
        // An outside recording still being read in as the meeting's track.
        case importing
        case recovered
        case ready

        // Its audio is still being written, so nothing reads or removes it yet.
        public var isTakingAudio: Bool { self == .recording || self == .importing }
    }

    public struct Speaker: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var personId: UUID?
        // A person whose voice is close but not clear enough to name; offered first when renaming.
        public var suggestion: UUID?
        // Named from the one person invited, not from the voice.
        public var isGuess: Bool?
        // Named by the user, so the app never offers to take the name back.
        public var isNamedByUser: Bool?

        public init(
            id: String, name: String, personId: UUID? = nil, suggestion: UUID? = nil, isGuess: Bool? = nil, isNamedByUser: Bool? = nil
        ) {
            self.id = id
            self.name = PersonName.plain(name)
            self.personId = personId
            self.suggestion = suggestion
            self.isGuess = isGuess
            self.isNamedByUser = isNamedByUser
        }
    }

    // A change the user made to a speaker, made again after every split so it outlives one.
    public struct SpeakerEdit: Codable, Sendable, Equatable {
        public enum Change: Codable, Sendable, Equatable {
            case named(name: String, person: UUID?)
            case merged(into: String)
            case notThisPerson
        }

        public var speaker: String
        public var change: Change

        public init(speaker: String, change: Change) {
            self.speaker = speaker
            self.change = change
        }
    }

    public struct Attendee: Codable, Sendable, Equatable {
        public enum Source: String, Codable, Sendable {
            case calendar
            case callWindow
        }

        public var name: String
        public var source: Source

        public init(name: String, source: Source) {
            self.name = PersonName.plain(name)
            self.source = source
        }

        // Files written before names were read from the call window hold the calendar's names as plain strings.
        public init(from decoder: any Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: name, source: .calendar)
            } else {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                self.init(name: try fields.decode(String.self, forKey: .name), source: try fields.decode(Source.self, forKey: .source))
            }
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            case waiting
            case running
            case done
            case failed
        }

        public var status: Status
        public var waiting: WaitReason?
        // The Problem code a failed step stopped with; never its message, so a reworded message still reads back.
        public var problem: String?
        // When a running step started, for the time it has taken so far.
        public var since: Date?

        public init(_ status: Status, for waiting: WaitReason? = nil, problem: String? = nil, since: Date? = nil) {
            self.status = status
            self.waiting = waiting
            self.problem = problem
            self.since = since
        }

        private enum CodingKeys: String, CodingKey {
            case status, waiting, problem, since
        }

        private enum OldKeys: String, CodingKey {
            case reason
        }

        // Older files kept a sentence as the reason: a waiting step reads it back as what it waits for, a failed one shows its step's failure.
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            status = try fields.decode(Status.self, forKey: .status)
            since = try fields.decodeIfPresent(Date.self, forKey: .since)
            problem = try fields.decodeIfPresent(String.self, forKey: .problem)
            let sentence = try decoder.container(keyedBy: OldKeys.self).decodeIfPresent(String.self, forKey: .reason)
            waiting = try fields.decodeIfPresent(String.self, forKey: .waiting).flatMap(WaitReason.init(rawValue:))
                ?? sentence.flatMap(WaitReason.init(sentence:))
        }
    }

    public enum Stop: String, Codable, Sendable {
        case asked
        case lowDisk
        case sleep
    }

    // macOS never says whether other apps' sound may be recorded, so a silent track blames permission only until sound came once.
    public enum SystemSound: String, Codable, Sendable {
        case heard
        case nothingPlayed
        // Silent, with recording other apps' sound never known to be allowed.
        case unheard
        case notCaptured
    }

    public struct Steps: Codable, Sendable, Equatable {
        public var transcript = Step(.waiting)
        public var echo = Step(.waiting)
        public var speakers = Step(.waiting)
        public var summary = Step(.waiting)

        var needAudio: Bool { [echo, transcript, speakers].contains { $0.status == .waiting || $0.status == .running } }
    }

    public static let currentVersion = 1

    public var version = Meeting.currentVersion
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var durationMs = 0
    // The call app's bundle id, or empty.
    public var app: String
    public var source: Source
    public var attendees: [Attendee] = []
    public var speakers: [Speaker] = []
    public var speakerEdits: [SpeakerEdit] = []
    public var steps = Steps()
    public var template: String
    // Empty for the summary model chosen in settings; see SummaryModels.
    public var summaryModel = ""
    public var pinned = false
    public var state: State
    public var systemSound = SystemSound.heard
    // Percent of each track padded or cut to hold it to the meeting's clock: sound its device lost, or sent at a rate it did not report.
    public var microphoneLostPercent = 0
    public var systemLostPercent = 0
    // A line edited by hand, which a new transcript would replace; cleared when one is written.
    public var linesEdited = false
    public var stop = Stop.asked
    // The models that wrote the transcript and the summary, by name; empty until that step is done.
    public var speechModel = ""
    public var summaryMadeWith = ""
    // How many people the speakers step finds on the other side, or in the room with one track; 0 lets it decide.
    public var speakerCount = 0
    // How many people share the owner's microphone in a call; 0 lets the speakers step decide.
    public var ownSideCount = 0
    // The language code the user chose for the meeting; empty to detect it.
    public var language = ""
    // The title was written by the summary model, so a new summary may write it again.
    public var titleIsMade = false

    public init(id: UUID = UUID(), title: String, startedAt: Date, app: String, source: Source, template: String, state: State) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.app = app
        self.source = source
        self.template = template
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case id, title, startedAt, durationMs, app, source, attendees, speakers, speakerEdits, steps, template, summaryModel, pinned
        case state, systemSound, microphoneLostPercent, systemLostPercent, linesEdited, stop, speechModel, summaryMadeWith, language
        case titleIsMade, speakerCount, ownSideCount
    }

    // Before systemSound, a silent call was kept as othersNotRecorded; a rewrite leaves that key in the file.
    private enum OldKeys: String, CodingKey {
        case othersNotRecorded
    }

    // Files written before speakerEdits, linesEdited, summaryModel, stop, the model names, the language, titleIsMade or the
    // recorded shares were kept have no such keys.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        id = try fields.decode(UUID.self, forKey: .id)
        title = try fields.decode(String.self, forKey: .title)
        startedAt = try fields.decode(Date.self, forKey: .startedAt)
        durationMs = try fields.decode(Int.self, forKey: .durationMs)
        app = try fields.decode(String.self, forKey: .app)
        source = try fields.decode(Source.self, forKey: .source)
        attendees = try fields.decode([Attendee].self, forKey: .attendees)
        // Names saved surname first, before they were written one way, read like the rest.
        speakers = try fields.decode([Speaker].self, forKey: .speakers).map { speaker in
            var speaker = speaker
            speaker.name = PersonName.plain(speaker.name)
            return speaker
        }
        speakerEdits = try fields.decodeIfPresent([SpeakerEdit].self, forKey: .speakerEdits)?.map { edit in
            guard case .named(let name, let person) = edit.change else { return edit }
            return SpeakerEdit(speaker: edit.speaker, change: .named(name: PersonName.plain(name), person: person))
        } ?? []
        steps = try fields.decode(Steps.self, forKey: .steps)
        template = try fields.decode(String.self, forKey: .template)
        summaryModel = try fields.decodeIfPresent(String.self, forKey: .summaryModel) ?? ""
        pinned = try fields.decode(Bool.self, forKey: .pinned)
        state = try fields.decode(State.self, forKey: .state)
        let wasSilent = try decoder.container(keyedBy: OldKeys.self).decodeIfPresent(Bool.self, forKey: .othersNotRecorded) ?? false
        systemSound = try fields.decodeIfPresent(SystemSound.self, forKey: .systemSound) ?? (wasSilent ? .unheard : .heard)
        microphoneLostPercent = try fields.decodeIfPresent(Int.self, forKey: .microphoneLostPercent) ?? 0
        systemLostPercent = try fields.decodeIfPresent(Int.self, forKey: .systemLostPercent) ?? 0
        linesEdited = try fields.decodeIfPresent(Bool.self, forKey: .linesEdited) ?? false
        stop = try fields.decodeIfPresent(Stop.self, forKey: .stop) ?? .asked
        speechModel = try fields.decodeIfPresent(String.self, forKey: .speechModel) ?? ""
        summaryMadeWith = try fields.decodeIfPresent(String.self, forKey: .summaryMadeWith) ?? ""
        speakerCount = try fields.decodeIfPresent(Int.self, forKey: .speakerCount) ?? 0
        ownSideCount = try fields.decodeIfPresent(Int.self, forKey: .ownSideCount) ?? 0
        language = try fields.decodeIfPresent(String.self, forKey: .language) ?? ""
        titleIsMade = try fields.decodeIfPresent(Bool.self, forKey: .titleIsMade) ?? false
    }
}

extension Meeting {
    // The line on unheard sound comes first, where the page puts its settings button.
    public var soundNotes: [String] {
        var notes: [String] = []
        switch systemSound {
        case .unheard: notes.append("Other people's sound was not recorded.")
        case .notCaptured: notes.append("This Mac's sound could not be recorded.")
        // Started by hand it may be a meeting in a room, where nothing playing is the usual case.
        case .nothingPlayed: if source == .call { notes.append("Nothing played on this Mac, so only your microphone was recorded.") }
        case .heard: notes += [Self.lostLine(systemLostPercent, of: "other people's sound")].compactMap { $0 }
        }
        return notes + [Self.lostLine(microphoneLostPercent, of: "your microphone")].compactMap { $0 }
    }

    // Under 10% is what device changes cost a short meeting.
    private static func lostLine(_ percent: Int, of track: String) -> String? {
        guard percent >= 10 else { return nil }
        guard percent < 95 else { return "Almost none of \(track) was recorded." }
        return "About \(Int((Double(percent) / 10).rounded()) * 10)% of \(track) was not recorded."
    }

    mutating func keep(_ recording: MeetingRecording, systemAudioWasAllowed: Bool) {
        durationMs = Int(recording.duration / .milliseconds(1))
        microphoneLostPercent = Int((100 * recording.microphoneLost).rounded())
        systemLostPercent = Int((100 * recording.systemLost).rounded())
        systemSound = if !recording.systemDelivered {
            .notCaptured
        } else if recording.heardSystemSound {
            .heard
        } else {
            systemAudioWasAllowed ? .nothingPlayed : .unheard
        }
    }

    // A name already listed, in any case, keeps its first source. True when a name was added.
    @discardableResult
    mutating func addAttendees(_ names: [String], from source: Attendee.Source) -> Bool {
        let count = attendees.count
        for name in names.map(PersonName.plain) where !attendees.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            attendees.append(Attendee(name: name, source: source))
        }
        return attendees.count > count
    }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    var fields: [String: JSONValue] {
        get throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.formatted(Self.timestamp))
            }
            return try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(self))
        }
    }

    init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.timestamp.parse(decoder.singleValueContainer().decode(String.self))
        }
        self = try decoder.decode(Self.self, from: json)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [CodingKeys.version], debugDescription: "unknown meeting version \(version)")
            )
        }
    }
}
