import NarrariKit
import Testing

@MainActor
struct CleanupEngineSlotTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()
    private let clock = TestClock()
    private let engine = FakeCleanupEngine { $0 }
    private let idleLimit = Duration.seconds(CleanupSettings.idleLimit.defaultValue)

    private func loadedSlot() async -> CleanupEngineSlot {
        let slot = CleanupEngineSlot(
            settings: settings.store, keychain: FakeKeychain(), store: ModelStore(root: folder.url),
            clock: clock, choose: { [engine] _ in engine }
        )
        slot.reload()
        await clock.waitForSleepers(1)
        return slot
    }

    @Test func model_unloads_once_idle_for_the_limit_and_loads_again_when_a_dictation_starts() async {
        let slot = await loadedSlot()

        clock.advance(by: idleLimit - .seconds(1))
        #expect(clock.pendingSleepers == 1)
        clock.advance(by: .seconds(1))
        await engine.unloads.waitForArrivals(1)

        slot.hold()
        await engine.loads.waitForArrivals(2)
        slot.release()
        await clock.waitForSleepers(1)
        clock.advance(by: idleLimit)
        await engine.unloads.waitForArrivals(2)
    }

    @Test func dictation_inside_the_idle_limit_keeps_the_model() async {
        let slot = await loadedSlot()
        clock.advance(by: idleLimit - .seconds(1))

        slot.hold()
        clock.advance(by: idleLimit)

        #expect(clock.pendingSleepers == 0)
        #expect(engine.unloads.arrivals == 0)
        #expect(engine.loads.arrivals == 1)
        slot.release()
    }
}
