import Foundation

// What the user says about a speaker, and what voice memory learns from it.
public struct SpeakerRenaming: Sendable {
    private let store: MeetingStore
    private let memory: VoiceMemory
    private let settings: SettingsStore

    public init(store: MeetingStore, memory: VoiceMemory, settings: SettingsStore) {
        self.store = store
        self.memory = memory
        self.settings = settings
    }

    // The meeting's print of that voice is taught to the person.
    public func rename(_ speaker: String, in meeting: UUID, toPerson person: UUID) async throws {
        guard try await name(speaker, in: meeting, person: person) else { return }
        try await recordName(of: speaker, in: meeting)
    }

    // A name nobody has yet becomes a person, when there is a voice to remember them by.
    public func rename(_ speaker: String, in meeting: UUID, to name: String) async throws {
        if let known = try await memory.people().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return try await rename(speaker, in: meeting, toPerson: known.id)
        }
        if settings.value(MeetingsSettings.usesVoiceMemory), try await store.voices(of: meeting)[speaker] != nil {
            try await self.name(speaker, in: meeting, person: try await memory.newPerson(named: name).id)
        } else {
            try await set(speaker, in: meeting, name: name, person: nil, byUser: true)
        }
        try await recordName(of: speaker, in: meeting)
    }

    // The speaker goes back to their number, and the person forgets this meeting's print.
    public func notThisPerson(_ speaker: String, in meeting: UUID) async throws {
        try await unname(speaker, in: meeting)
        try await record(Meeting.SpeakerEdit(speaker: speaker, change: .notThisPerson), in: meeting)
    }

    // The person and every print of their voice go; past meetings keep their name as plain text.
    public func forget(_ person: UUID) async throws {
        try await memory.delete(person)
        for meeting in try await store.meetings().meetings
        where meeting.speakers.contains(where: { $0.personId == person || $0.suggestion == person }) {
            let unnamed = try await store.update(meeting.id) { meeting in
                var unnamed: [String] = []
                for index in meeting.speakers.indices {
                    if meeting.speakers[index].personId == person {
                        unnamed.append(meeting.speakers[index].id)
                        meeting.speakers[index].personId = nil
                    }
                    if meeting.speakers[index].suggestion == person { meeting.speakers[index].suggestion = nil }
                }
                return unnamed
            }
            var voices = try await store.voices(of: meeting.id)
            unnamed.forEach { voices[$0] = nil }
            try await store.write(voices: voices, of: meeting.id)
        }
    }

    // Their lines become the other speaker's and their print goes; voice memory is left as it is.
    public func merge(_ speaker: String, into other: String, in meeting: UUID) async throws {
        guard try await combine(speaker, into: other, in: meeting) else { return }
        try await record(Meeting.SpeakerEdit(speaker: speaker, change: .merged(into: other)), in: meeting)
    }

    // The user's changes made again, in order, after the speakers step split the meeting anew. A name given before any
    // split was on everyone else as one speaker, so it goes to `others`, the one of them heard most, as if chosen now.
    func replay(in meeting: UUID, others: String?) async throws {
        let edits = try await store.update(meeting) { changed in
            let edits = changed.speakerEdits
            changed.speakerEdits.removeAll { $0.speaker == MeetingTranscript.othersID }
            return edits
        }
        let people = Set(try await memory.people().map(\.id))
        for edit in edits {
            if edit.speaker == MeetingTranscript.othersID {
                guard let others, case .named(let name, let person) = edit.change else { continue }
                if let person, people.contains(person) {
                    try await rename(others, in: meeting, toPerson: person)
                } else {
                    try await rename(others, in: meeting, to: name)
                }
                continue
            }
            switch edit.change {
            case .named(_, let person?) where people.contains(person):
                let found = try await store.meeting(meeting).speakers.first { $0.personId == person }?.id
                try await name(found ?? edit.speaker, in: meeting, person: person)
            case .named(let name, _): try await set(edit.speaker, in: meeting, name: name, person: nil, byUser: true)
            case .merged(let other): try await combine(edit.speaker, into: other, in: meeting)
            case .notThisPerson: try await unname(edit.speaker, in: meeting)
            }
        }
    }

    @discardableResult
    private func name(_ speaker: String, in meeting: UUID, person: UUID) async throws -> Bool {
        guard let found = try await memory.people().first(where: { $0.id == person }) else { return false }
        try await set(speaker, in: meeting, name: found.name, person: person, byUser: true)
        if settings.value(MeetingsSettings.usesVoiceMemory), let print = try await store.voices(of: meeting)[speaker] {
            try await memory.learn(print, from: meeting, for: person)
        }
        return true
    }

    private func unname(_ speaker: String, in meeting: UUID) async throws {
        let person = try await store.meeting(meeting).speakers.first { $0.id == speaker }?.personId
        try await set(speaker, in: meeting, name: SpeakerCast.numberedName(of: speaker), person: nil, byUser: false)
        if let person { try await memory.unlearn(printFrom: meeting, for: person) }
    }

    @discardableResult
    private func combine(_ speaker: String, into other: String, in meeting: UUID) async throws -> Bool {
        let combined = try await store.update(meeting) { changed in
            guard speaker != other, changed.speakers.contains(where: { $0.id == speaker }), changed.speakers.contains(where: { $0.id == other })
            else { return false }
            changed.speakers.removeAll { $0.id == speaker }
            return true
        }
        guard combined else { return false }
        var voices = try await store.voices(of: meeting)
        voices[speaker] = nil
        try await store.write(voices: voices, of: meeting)
        let segments = try await store.transcript(of: meeting).map { segment in
            var moved = segment
            if moved.speaker == speaker { moved.speaker = other }
            return moved
        }
        try await store.write(segments, of: meeting)
        return true
    }

    private func recordName(of speaker: String, in meeting: UUID) async throws {
        guard let named = try await store.meeting(meeting).speakers.first(where: { $0.id == speaker }) else { return }
        try await record(Meeting.SpeakerEdit(speaker: speaker, change: .named(name: named.name, person: named.personId)), in: meeting)
    }

    // A speaker's newest name or "not this person" replaces the one before, so an old name is never taught again.
    private func record(_ edit: Meeting.SpeakerEdit, in meeting: UUID) async throws {
        try await store.update(meeting) { changed in
            if case .merged = edit.change {} else {
                changed.speakerEdits.removeAll { old in
                    if case .merged = old.change { return false }
                    return old.speaker == edit.speaker
                }
            }
            changed.speakerEdits.append(edit)
        }
    }

    private func set(_ speaker: String, in meeting: UUID, name: String, person: UUID?, byUser: Bool) async throws {
        try await store.update(meeting) { changed in
            guard let index = changed.speakers.firstIndex(where: { $0.id == speaker }) else { return }
            changed.speakers[index] = Meeting.Speaker(id: speaker, name: name, personId: person, isNamedByUser: byUser ? true : nil)
        }
    }
}
