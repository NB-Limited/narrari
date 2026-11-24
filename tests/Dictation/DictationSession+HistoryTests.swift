import Foundation
import NarrariKit
import Testing

@MainActor
struct DictationSessionHistoryTests {
    @Test func confirmed_discard_keeps_the_audio_with_a_discarded_line() async throws {
        let rig = SessionRig()
        await rig.pressAndConfirm()

        rig.hotkeys.send(.escape, at: rig.clock.seconds)
        await rig.session.shutdown()

        let entry = try await rig.onlyEntry()
        #expect(entry.outcome == .discarded)
        #expect(rig.hasAudio(entry))
        #expect(rig.session.notice == .discarded)
        #expect(rig.sounds.played.last == .ignored)
    }

    @Test func history_gets_an_open_line_at_confirm_and_a_final_line_with_the_same_id() async throws {
        let rig = SessionRig()

        await rig.dictate()

        let dayFile = try #require(try dayFiles(in: rig.history.root).first)
        let lines = try String(contentsOf: dayFile, encoding: .utf8).split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(lines.count == 2)
        let ids = lines.compactMap { $0["id"] as? String }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 1)
        #expect(lines[0]["outcome"] == nil)
        #expect(lines[1]["outcome"] as? String == "pasted")
    }

    @Test func delete_all_history_during_a_dictation_keeps_that_dictation_and_its_audio() async throws {
        let rig = SessionRig()
        var historyChanges = rig.session.historyChanges.makeAsyncIterator()
        await rig.dictate()
        await historyChanges.next()
        let earlier = try await rig.onlyEntry()
        await rig.pressAndConfirm()
        await historyChanges.next()
        let page = HistoryPageModel(
            store: rig.history, meetings: MeetingStore(root: rig.folder.url.appending(path: "Meetings"), trash: { _ in }), settings: rig.settings.mirror,
            activeDictation: { rig.session.activeDictationID }
        )

        page.requestDeleteAll()
        await page.confirmDeleteAll()
        rig.release()
        await rig.session.shutdown()

        let kept = try await rig.onlyEntry()
        #expect(kept.id != earlier.id)
        #expect(kept.outcome == .pasted)
        #expect(rig.hasAudio(kept))
        #expect(!rig.hasAudio(earlier))
    }

    @Test func outside_speech_fallback_is_noted_in_history() async throws {
        let outside = FakeTranscriber(name: "whisper-1") { _ in
            Transcript(text: "hello from the test", audioSeconds: 1, fallbackReason: .timedOut)
        }
        let rig = SessionRig(outside: outside)
        try rig.modes.edit { book in
            try book.update(Mode(id: Mode.dictation.id, name: "Dictation", speech: .outside))
        }

        await rig.dictate()

        let entry = try await rig.onlyEntry()
        #expect(entry.speechFallback == SpeechFallbackReason.timedOut.rawValue)
        #expect(entry.speechModel == "Fake speech")
        #expect(entry.outcome == .pasted)
    }
}

private func dayFiles(in folder: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
}
