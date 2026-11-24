import NarrariKit
import Testing

@MainActor
struct SettingsCommandTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["settings"] + arguments)?.run(in: .throwaway(in: folder, settings: settings.store))
    }

    private func listed(_ key: String) async -> String? {
        await run()?.output.split(separator: "\n").first { $0.dropFirst(2).hasPrefix(key + " ") }.map(String.init)
    }

    @Test func wrong_value_is_refused_with_the_allowed_ones() async {
        let reply = await run("set", "pill.look", "frosted")

        #expect(reply?.status == 1)
        #expect(reply?.errors == "frosted is not a value for pill.look. Use one of smoked, clear, solid, gloss, colour, halo, compact, inline.\n")
        #expect(settings.store.hasValue(for: PillSettings.look) == false)
        #expect(await run("set", "dictation.holdThreshold", "nan")?.status == 1)
    }

    @Test func wrong_key_is_refused_with_the_keys_there_are() async {
        let reply = await run("get", "pill.sparkle")

        #expect(reply?.status == 1)
        #expect(reply?.errors.hasPrefix("pill.sparkle is not a setting. The settings are:\n") == true)
        #expect(reply?.errors.contains("  pill.look\n") == true)
    }

    @Test func changed_setting_is_marked_until_it_is_reset() async {
        #expect(await listed("pill.look")?.hasPrefix("  ") == true)

        #expect(await run("set", "pill.look", "clear")?.status == 0)
        #expect(await run("set", "dictation.holdThreshold", "0.8")?.status == 0)
        #expect(settings.store.value(PillSettings.look) == .clear)
        #expect(settings.store.value(DictationSettings.holdThreshold) == 0.8)
        #expect(await listed("pill.look")?.hasPrefix("* ") == true)
        #expect(await run("get", "pill.look")?.output == "clear\n")

        #expect(await run("reset", "pill.look")?.status == 0)
        #expect(settings.store.value(PillSettings.look) == .smoked)
        #expect(await listed("pill.look")?.hasPrefix("  ") == true)
    }
}
