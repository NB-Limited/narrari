import Foundation
import NarrariKit
import Synchronization
import Testing

// Loads only once its gate opens, as a model read from disk takes seconds.
private final class SlowEngine: CleanupEngine {
    let name: String
    let runsInApp = true
    let gate: Gate
    let loaded = Gate.counter()
    private let current = Mutex(ModelState.missing)

    init(_ name: String, gate: Gate = .counter()) {
        self.name = name
        self.gate = gate
    }

    var state: ModelState { current.withLock { $0 } }

    func load() async throws {
        try await gate.pass()
        current.withLock { $0 = .ready }
        try await loaded.pass()
    }

    func unload() async {
        current.withLock { $0 = .missing }
    }

    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String { transcript }
}

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

    @Test func a_model_changed_again_while_the_first_still_loads_is_let_go_once_that_load_ends() async {
        let first = SlowEngine("first", gate: Gate())
        let second = SlowEngine("second")
        let chosen = Mutex([first, second])
        let slot = CleanupEngineSlot(
            settings: settings.store, keychain: FakeKeychain(), store: ModelStore(root: folder.url),
            clock: clock, choose: { _ in chosen.withLock { $0.removeFirst() } }
        )

        slot.reload()
        await first.gate.waitForArrivals(1)
        slot.reload()
        first.gate.open()
        await first.loaded.waitForArrivals(1)
        await second.loaded.waitForArrivals(1)

        #expect(first.state == .missing)
        #expect(second.state == .ready)
    }

    @Test func model_on_this_mac_loads_at_the_first_dictation_not_at_launch() async throws {
        let model = folder.url.appending(path: "huggingface/models--" + ModelReference(CleanupSettings.localModel.defaultValue).id
            .replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let slot = CleanupEngineSlot(
            settings: settings.store, keychain: FakeKeychain(), store: ModelStore(root: folder.url),
            clock: clock, choose: { [engine] _ in engine }
        )

        slot.start()
        let loadsAtLaunch = engine.loads.arrivals
        slot.hold()
        await engine.loads.waitForArrivals(1)
        slot.release()
        await clock.waitForSleepers(1)
        clock.advance(by: idleLimit)
        await engine.unloads.waitForArrivals(1)

        #expect(loadsAtLaunch == 0)
        #expect(slot.current != nil)
    }
}
