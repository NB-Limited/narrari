import NarrariKit
import Testing

@MainActor
private final class FakeOutput: DeviceMuteSwitch {
    let hasOwnMute: Bool
    var works = true
    private(set) var isMuted = false

    init(hasOwnMute: Bool) {
        self.hasOwnMute = hasOwnMute
    }

    func defaultOutputUID() -> String? { "monitor" }
    func hasMute(_ uid: String) -> Bool { hasOwnMute }
    func isMuted(_ uid: String) -> Bool { isMuted }

    func setMuted(_ isMuted: Bool, _ uid: String) -> Bool {
        guard hasOwnMute, works else { return false }
        self.isMuted = isMuted
        return true
    }
}

@MainActor
private final class FakeTap: OtherAppsSilencer {
    var works = true
    private(set) var isSilencing = false

    func silence(outputUID: String) async -> Bool {
        isSilencing = works
        return works
    }

    func restore() async {
        isSilencing = false
    }
}

@MainActor
struct MediaControlTests {
    private let settings = ThrowawaySettings()
    private let tap = FakeTap()

    private func media(_ output: FakeOutput) -> MediaControl {
        MediaControl(settings: settings.store, device: output, otherApps: tap)
    }

    @Test func output_with_its_own_mute_is_muted_and_unmuted_without_touching_other_apps() async {
        let output = FakeOutput(hasOwnMute: true)
        let media = media(output)

        await media.muteOutput()
        #expect(output.isMuted)
        #expect(!tap.isSilencing)
        #expect(media.canMuteOutput())

        await media.restoreOutput()
        #expect(!output.isMuted)
    }

    @Test func output_without_mute_silences_other_apps_until_the_dictation_ends() async {
        let media = media(FakeOutput(hasOwnMute: false))

        await media.muteOutput()
        #expect(tap.isSilencing)
        #expect(media.canMuteOutput())

        await media.restoreOutput()
        #expect(!tap.isSilencing)
    }

    @Test(arguments: [false, true])
    func output_cannot_be_muted_after_its_mute_fails(hasOwnMute: Bool) async {
        let output = FakeOutput(hasOwnMute: hasOwnMute)
        output.works = false
        tap.works = false
        let media = media(output)

        await media.muteOutput()
        #expect(!media.canMuteOutput())
        #expect(settings.store.value(DictationSettings.mutedOutputUID).isEmpty)
    }

    @Test func other_sound_stays_on_while_a_meeting_records_because_muting_would_silence_the_call() async throws {
        let folder = TemporaryFolder()
        let replay = Replay(microphone: speech(seconds: 1), system: speech(seconds: 1))
        let meeting = MeetingRecorder(
            settings: settings.store, permissions: Permissions(settings: settings.store, access: .fixed(), microphoneStatus: { .authorized }),
            inputs: replay, system: replay, freeSpace: { _ in 50_000_000_000 }, hostNow: { replay.clock.hostTime },
            clock: TestClock()
        )
        let output = FakeOutput(hasOwnMute: true)
        let media = MediaControl(settings: settings.store, device: output, otherApps: tap, meeting: meeting)

        try meeting.start(in: folder.url)
        await media.muteOutput()
        #expect(!output.isMuted)
        #expect(!tap.isSilencing)

        meeting.stop()
        await media.muteOutput()
        #expect(output.isMuted)
    }
}
