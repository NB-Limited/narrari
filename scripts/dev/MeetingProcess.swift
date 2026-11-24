import Foundation
import NarrariKit

// A scratch data folder and models folder stand in for the real ones; nothing here reads the owner's data.
struct ScratchMeetings {
    let store: MeetingStore
    let settings: SettingsStore
    let models: ModelStore
    let data: URL

    init(data dataFolder: String, models modelsFolder: String) throws {
        data = URL(filePath: dataFolder)
        store = MeetingStore(root: data.appending(path: "Meetings"), trash: MeetingStore.moveToTrash)
        guard let defaults = UserDefaults(suiteName: data.appending(path: "settings").path) else { throw CocoaError(.fileNoSuchFile) }
        settings = SettingsStore(defaults: defaults)
        models = ModelStore(root: URL(filePath: modelsFolder))
    }
}

func meetingModels(_ scratch: ScratchMeetings) async throws {
    let speech = ParakeetTranscriber(store: scratch.models, settings: scratch.settings)
    try await speech.load()
    await speech.unload()
    let folder = scratch.settings.value(SpeechSettings.localModel).folder
    print("\(folder): \(try scratch.models.bytesOnDisk(named: folder)) bytes")
    for model in AudioModel.allCases {
        try await model.download(into: scratch.models) { _ in }
    }
    for entry in ModelCatalogue.meetings {
        let listed = entry.metrics.diskBytes.map(String.init) ?? "none"
        print("\(entry.name), \(entry.licence ?? "no licence"): \(try scratch.models.bytesOnDisk(named: entry.id)) bytes, catalogue \(listed)")
    }
}

// Runs every step on each meeting in the scratch folder, as the app would after a meeting ends, the summary with the clean-up model.
@MainActor
func meetingProcess(_ scratch: ScratchMeetings) async throws {
    let pipeline = TextPipeline(
        cleanup: CleanupService(engine: nil, settings: scratch.settings), prompts: PromptStore(root: scratch.data),
        dictionary: DictionaryStore(root: scratch.data), settings: scratch.settings
    )
    let transcription = FileTranscription(store: scratch.models, settings: scratch.settings, dictionary: DictionaryStore(root: scratch.data))
    let echo = EchoRemoval(models: scratch.models)
    let slot = CleanupEngineSlot(settings: scratch.settings, keychain: NoKeys(), store: scratch.models)
    let summary = SummaryService(
        templates: SummaryTemplateFolder(url: scratch.data.appending(path: "Templates"), builtIns: SummaryTemplateFolder.bundled),
        engines: CleanupSummaryEngines(slot: slot, settings: scratch.settings, keychain: NoKeys(), store: scratch.models),
        dictation: NoDictation(), settings: scratch.settings, clock: ContinuousClock()
    )
    let processing = MeetingProcessing(
        store: scratch.store, echo: echo,
        transcript: MeetingTranscript(
            transcribe: { try await transcription.run($0, upTo: nil, progress: $1) }, pipeline: pipeline, ownerName: "Owner",
            modelName: { transcription.modelName }
        ),
        speakers: MeetingSpeakers(
            models: scratch.models, memory: VoiceMemory(folder: scratch.data), pipeline: pipeline, settings: scratch.settings, ownerName: "Owner"
        ),
        summary: summary
    )
    for meeting in try await scratch.store.meetings().meetings {
        let peak = PeakMemory()
        let watcher = Task {
            while !Task.isCancelled {
                await peak.sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let start = ContinuousClock.now
        await processing.process(meeting.id)
        let elapsed = seconds(since: start)
        watcher.cancel()
        let steps = try await scratch.store.meeting(meeting.id).steps
        print("meeting \(meeting.id), \(Double(meeting.durationMs) / 1000) s")
        print(String(format: "processed in %.1f s, peak footprint %.0f MB", elapsed, await peak.megabytes))
        print("steps: echo \(steps.echo), transcript \(steps.transcript), speakers \(steps.speakers), summary \(steps.summary)")
        let system = try await scratch.store.audio(.system, of: meeting.id)
        if FileManager.default.fileExists(atPath: system.path) {
            let share = try await echo.echoShare(microphone: try await scratch.store.audio(.microphone, of: meeting.id), system: system)
            let cleaned = FileManager.default.fileExists(atPath: try await scratch.store.audio(.cleanedMicrophone, of: meeting.id).path)
            print(String(format: "echo share %.3f, cleaned track %@", share, cleaned ? "written" : "not written"))
        }
        print("speakers: " + (try await scratch.store.meeting(meeting.id).speakers.map { "\($0.id) \($0.name)" }.joined(separator: ", ")))
        for segment in try await scratch.store.transcript(of: meeting.id) {
            print(String(format: "%7.2f-%7.2f %@ %@: %@", segment.start, segment.end, segment.track.rawValue, segment.speaker, segment.text))
        }
    }
}
