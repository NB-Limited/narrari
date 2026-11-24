import Foundation
import Observation

// The People page in settings: whether voices are remembered, and the people voice memory knows.
@MainActor
@Observable
public final class PeoplePageModel {
    // people.json belongs to voice memory, which announces nothing; whoever renames or forgets someone outside this page posts it.
    public nonisolated static let changeKey = "people"

    public var usesVoiceMemory: Bool {
        get { settings[MeetingsSettings.usesVoiceMemory] }
        set { settings[MeetingsSettings.usesVoiceMemory] = newValue }
    }
    public private(set) var people: [VoiceMemory.Person] = []
    public var editing: UUID?
    public var pendingForget: UUID?

    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let memory: VoiceMemory
    @ObservationIgnored private let renaming: SpeakerRenaming

    public init(settings: SettingsMirror, memory: VoiceMemory, renaming: SpeakerRenaming) {
        self.settings = settings
        self.memory = memory
        self.renaming = renaming
        SettingsChanges.follow([PeoplePageModel.changeKey], by: self) { page in Task { await page.appear() } }
    }

    public func appear() async {
        do {
            people = try await memory.people().filter { !$0.isOwner }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            Log.failure("people-read", error: error)
        }
    }

    public func rename(_ person: UUID, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard !name.isEmpty else { return }
        do {
            try await memory.rename(person, to: name)
        } catch {
            Log.failure("person-rename", error: error)
        }
        await appear()
    }

    // The person and their voice go; meetings keep the name as text.
    public func forget(_ person: UUID) async {
        pendingForget = nil
        do {
            try await renaming.forget(person)
            Log.event("person-forgotten")
        } catch {
            Log.failure("person-forget", error: error)
        }
        await appear()
    }
}
