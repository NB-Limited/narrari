import Foundation
import NarrariKit
import Testing

struct HistoryStoreTests {
    private let folder = TemporaryFolder()
    private let store: HistoryStore
    private let utc: Calendar
    private let morning = try! Date("2026-11-19T09:30:00Z", strategy: .iso8601)

    init() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        self.utc = utc
        store = HistoryStore(root: folder.url, calendar: utc)
    }

    private func entry(_ outcome: HistoryEntry.Outcome? = nil, id: UUID = UUID(), text: String = "") -> HistoryEntry {
        HistoryEntry(id: id, startedAt: morning, durationMs: 2400, app: "com.apple.TextEdit", finalText: text,
                     audioFile: HistoryEntry.audioFileName(for: id), outcome: outcome)
    }

    private func appendRaw(_ text: String) throws {
        let day = try #require(folder.files(withExtension: "jsonl").first)
        let handle = try FileHandle(forWritingTo: day)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func writeAudio(for entry: HistoryEntry) throws {
        try Data("caff".utf8).write(to: store.audioURL(for: entry.id))
    }

    private func hasAudio(_ entry: HistoryEntry) -> Bool {
        FileManager.default.fileExists(atPath: store.audioURL(for: entry.id).path)
    }

    @Test func last_line_per_id_wins() async throws {
        let open = entry()
        try await store.append(open)
        try await store.append(entry(.pasted, id: open.id, text: "Hello, Anna."))

        let read = try await store.entries()

        #expect(read.entries.map(\.id) == [open.id])
        #expect(read.entries.first?.outcome == .pasted)
        #expect(read.entries.first?.finalText == "Hello, Anna.")
    }

    @Test func broken_line_and_unknown_version_are_skipped_and_counted() async throws {
        let first = entry(.pasted, text: "first")
        try await store.append(first)
        let line = try String(contentsOf: #require(folder.files(withExtension: "jsonl").first), encoding: .utf8)
        try appendRaw("{not json at all}\n")
        try appendRaw(line.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)
            .replacingOccurrences(of: first.id.uuidString, with: UUID().uuidString))
        let second = entry(.pasted, text: "second")
        try await store.append(second)

        let read = try await store.entries()

        #expect(Set(read.entries.map(\.id)) == [first.id, second.id])
        #expect(read.skipped == 2)
    }

    @Test func line_cut_off_by_a_crash_does_not_swallow_the_next_one() async throws {
        let first = entry(.pasted, text: "first")
        try await store.append(first)
        try appendRaw(#"{"v":1,"id":"6F1C"#)
        let second = entry(.pasted, text: "second")
        try await store.append(second)

        let read = try await store.entries()

        #expect(Set(read.entries.map(\.id)) == [first.id, second.id])
        #expect(read.skipped == 1)
    }

    @Test func dictation_left_open_by_a_crash_comes_back_failed_with_its_audio() async throws {
        let open = entry()
        try await store.append(open)
        try writeAudio(for: open)

        try await store.recover()

        let recovered = try #require(try await store.entries().entries.first)
        #expect(recovered.id == open.id)
        #expect(recovered.outcome == .failed)
        #expect(recovered.needsTranscription)
        #expect(hasAudio(open))
    }

    @Test func orphan_audio_file_is_adopted_as_a_failed_dictation() async throws {
        let id = UUID()
        try Data("caff".utf8).write(to: store.audioURL(for: id))

        try await store.recover()

        let adopted = try await store.entries().entries
        #expect(adopted.map(\.id) == [id])
        #expect(adopted.first?.outcome == .failed)
        #expect(adopted.first?.audioFile == HistoryEntry.audioFileName(for: id))
    }

    @Test func line_written_before_prompts_were_kept_loads_unchanged() async throws {
        try await store.append(entry(.pasted))
        let id = UUID()
        try appendRaw(
            #"{"app":"com.apple.Mail","audioFile":"\#(id.uuidString).caf","cleanup":{"model":"Qwen3.5 2B","reason":"","status":"cleaned"},"#
                + #""durationMs":3100,"finalText":"Hi Anna.","id":"\#(id.uuidString)","mode":"Email","outcome":"pasted","#
                + #""rawText":"hi anna","speechModel":"Parakeet v3","startedAt":"2026-11-19T09:31:00.000Z","v":1}"# + "\n"
        )

        let old = try #require(try await store.entries().entries.first { $0.id == id })

        #expect(old.finalText == "Hi Anna.")
        #expect(old.rawText == "hi anna")
        #expect(old.mode == "Email")
        #expect(old.cleanup.model == "Qwen3.5 2B")
        #expect(old.prompt == nil)
        #expect(!([.asSpoken] + PromptStore.builtIn.map(CleanupChoice.init)).contains { $0.made(old) })
    }

    @Test func deleted_entry_stays_hidden_and_its_audio_is_gone() async throws {
        let kept = entry(.pasted, text: "kept")
        let deleted = entry(.pasted, text: "deleted")
        for item in [kept, deleted] {
            try await store.append(item)
            try writeAudio(for: item)
        }

        try await store.delete(deleted)
        try await store.recover()

        #expect(try await store.entries().entries.map(\.id) == [kept.id])
        #expect(!hasAudio(deleted))
        #expect(hasAudio(kept))
    }

    @Test func delete_all_removes_every_dictation_and_its_audio() async throws {
        for item in [entry(.pasted), entry(.discarded)] {
            try await store.append(item)
            try writeAudio(for: item)
        }

        try await store.deleteAll()

        #expect(try await store.entries().entries.isEmpty)
        #expect(folder.files(withExtension: "caf").isEmpty)
    }

    @Test func delete_all_keeps_every_line_and_the_audio_of_a_kept_dictation() async throws {
        let recording = entry()
        let finished = entry(.pasted, text: "finished")
        for item in [finished, recording] {
            try await store.append(item)
            try writeAudio(for: item)
        }
        var reopened = recording
        reopened.durationMs = 9000
        try await store.append(reopened)

        try await store.deleteAll(keeping: [recording.id])

        let day = try #require(folder.files(withExtension: "jsonl").first)
        let lines = try String(contentsOf: day, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains(recording.id.uuidString) })
        #expect(try FileManager.default.attributesOfItem(atPath: day.path)[.posixPermissions] as? Int == 0o600)
        #expect(hasAudio(recording))
        #expect(!hasAudio(finished))
    }

    @Test func update_appends_to_an_entry_that_still_exists() async throws {
        let original = entry(.failed)
        try await store.append(original)
        var retranscribed = original
        retranscribed.finalText = "Hello, Anna."

        try await store.update(retranscribed)

        #expect(try await store.entries().entries.map(\.finalText) == ["Hello, Anna."])
    }

    @Test func update_refuses_an_entry_deleted_meanwhile() async throws {
        let original = entry(.failed)
        try await store.append(original)
        try await store.delete(original)
        var retranscribed = original
        retranscribed.finalText = "Hello, Anna."

        await #expect(throws: HistoryError.entryGone) { try await store.update(retranscribed) }

        #expect(try await store.entries().entries.isEmpty)
    }

    // The narrari command writes the same files from a process of its own.
    @Test func lines_written_by_another_store_are_read_with_this_stores_own() async throws {
        let outside = HistoryStore(root: folder.url, calendar: utc)
        let first = entry(.pasted, text: "first")
        try await store.append(first)
        #expect(try await store.entries().entries.map(\.id) == [first.id])

        let second = entry(.pasted, text: "second")
        try await outside.append(second)
        let third = entry(.pasted, text: "third")
        try await store.append(third)
        try await outside.delete(first)

        #expect(Set(try await store.entries().entries.map(\.finalText)) == ["second", "third"])
    }
}
