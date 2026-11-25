import NarrariKit
import Testing

@MainActor
private final class Heard {
    var names: [[String]] = []
}

@MainActor
struct CallWindowNamesTests {
    private static let zoom = "us.zoom.xos"
    private static let teams = "com.microsoft.teams2"

    private let settings = ThrowawaySettings()
    private let clock = TestClock()
    private let windows = FakeCallWindows()
    private let heard = Heard()
    private let names: CallWindowNames

    init() {
        names = CallWindowNames(source: windows, settings: settings.store, clock: clock, ownerName: "Mila Novak")
        settings.store.set(true, for: MeetingsSettings.readsCallWindowNames)
    }

    // Returns once the read made at start is over.
    private func firstRead(of app: String) async {
        names.start(app: app) { [heard] found in heard.names.append(found) }
        await clock.waitForSleepers(1)
    }

    @Test func reads_the_people_in_zooms_participants_panel_without_the_owner_or_their_labels() async {
        windows.state.withLock {
            $0.windows[Self.zoom] = FakeCallWindows.zoom([
                "Mila (Host, me)", "Ana Petrova (Co-host)", "Boris Ivanov (Guest)", "mila novak", "Vera Kostova (Acme)"
            ])
        }

        await firstRead(of: Self.zoom)
        await names.stop()

        #expect(heard.names == [["Ana Petrova", "Boris Ivanov", "Vera Kostova (Acme)"]])
    }

    @Test func the_owner_listed_the_way_a_company_directory_spells_them_is_left_out() async {
        windows.state.withLock {
            $0.windows[Self.zoom] = FakeCallWindows.zoom(["Novak,Milena M.M.", "Novak", "Petrova,Ana A.", "Mira Kostova"])
        }

        await firstRead(of: Self.zoom)
        await names.stop()

        #expect(heard.names == [["Novak", "Petrova,Ana A.", "Mira Kostova"]])
    }

    @Test func reads_teams_in_its_assistive_mode_and_puts_the_mode_back_at_stop() async {
        windows.state.withLock {
            $0.windows[Self.teams] = FakeCallWindows.teams(joined: ["Mila Novak (You)", "Ana Petrova (Organiser)"], invited: ["Boris Ivanov"])
        }

        await firstRead(of: Self.teams)
        #expect(windows.state.withLock { $0.assistiveModes[Self.teams] } == true)
        await names.stop()

        #expect(windows.state.withLock { $0.assistiveModes[Self.teams] } == false)
        #expect(heard.names == [["Ana Petrova"]])
    }

    @Test func a_window_of_another_shape_gives_no_names() async {
        let person = WindowElement(role: "AXGroup", children: [WindowElement(role: "AXStaticText", value: "Ana Petrova")])
        let reshaped = WindowElement(role: "AXWindow", title: "Zoom Meeting", children: [
            WindowElement(role: "AXGroup", title: "Participants (1)", children: [person])
        ])
        windows.state.withLock { $0.windows[Self.zoom] = [reshaped] }

        await firstRead(of: Self.zoom)
        await names.stop()

        #expect(windows.state.withLock { $0.looks } == 1)
        #expect(heard.names.isEmpty)
    }

    @Test func with_the_switch_off_no_window_is_looked_at() async {
        settings.store.set(false, for: MeetingsSettings.readsCallWindowNames)
        windows.state.withLock { $0.windows[Self.teams] = FakeCallWindows.teams(joined: ["Ana Petrova"], invited: []) }

        await firstRead(of: Self.teams)
        clock.advance(by: .seconds(30))
        await clock.waitForSleepers(1)
        await names.stop()

        #expect(windows.state.withLock { $0.looks } == 0)
        #expect(heard.names.isEmpty)
    }
}
