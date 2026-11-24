import Foundation
import NarrariKit
import Synchronization

// Core Audio's process list, set by the test; a change is reviewed before set returns, unless the test keeps it untold.
final class FakeProcesses: AudioProcessSource {
    private struct State {
        var list: [AudioProcess] = []
        var onChange: (@Sendable () async -> Void)?
    }

    private let state = Mutex(State())

    func processes(reading reads: (pid_t, String) -> AudioProcessReads) -> [AudioProcess] {
        state.withLock { $0.list }.map { process in
            let asked = reads(process.pid, process.bundleID)
            return AudioProcess(
                pid: process.pid, bundleID: process.bundleID,
                isRunningInput: asked.contains(.input) && process.isRunningInput, isRunningOutput: asked.contains(.output) && process.isRunningOutput
            )
        }
    }
    func watch(_ onChange: @escaping @Sendable () async -> Void) { state.withLock { $0.onChange = onChange } }
    func unwatch() { state.withLock { $0.onChange = nil } }

    func set(_ list: [AudioProcess], isTold: Bool = true) async {
        let onChange = state.withLock { state in
            state.list = list
            return state.onChange
        }
        if isTold { await onChange?() }
    }

    static func app(_ bundleID: String, input: Bool, output: Bool, pid: pid_t = 4_242) -> AudioProcess {
        AudioProcess(pid: pid, bundleID: bundleID, isRunningInput: input, isRunningOutput: output)
    }
}

// Gives what EventKit would: every event that overlaps the asked span, all-day ones included.
struct FakeCalendar: CalendarSource {
    let events: [CalendarEvent]

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        events.filter { $0.start < end && $0.end > start }
    }
}

final class FakeScreenWatcher: ScreenWatcher {
    // Nil stands for a macOS without the check.
    let answer = Mutex<Bool?>(false)

    func isWatched() -> Bool? { answer.withLock { $0 } }
}

// Call apps' windows as the test draws them; counts every look, so a test can prove none was taken.
final class FakeCallWindows: CallWindowSource {
    struct State {
        var windows: [String: [WindowElement]] = [:]
        var assistiveModes: [String: Bool] = [:]
        var looks = 0
    }

    let state = Mutex(State())

    func windows(of app: String) -> [WindowElement] {
        state.withLock { state in
            state.looks += 1
            return state.windows[app] ?? []
        }
    }

    func assistiveMode(of app: String) -> Bool {
        state.withLock { state in
            state.looks += 1
            return state.assistiveModes[app] ?? false
        }
    }

    func setAssistiveMode(_ isOn: Bool, of app: String) {
        state.withLock { state in
            state.looks += 1
            state.assistiveModes[app] = isOn
        }
    }

    // Zoom's meeting window with its participants panel docked beside the chat.
    static func zoom(_ people: [String]) -> [WindowElement] {
        [
            WindowElement(role: "AXWindow", title: "Zoom Meeting", children: [
                WindowElement(role: "AXGroup", title: "Chat", children: [table(["See you at three"])]),
                WindowElement(role: "AXGroup", title: "Participants (\(people.count))", children: [table(people)])
            ])
        ]
    }

    // Teams' meeting window with its people panel, those who joined apart from those only invited.
    static func teams(joined: [String], invited: [String]) -> [WindowElement] {
        [
            WindowElement(role: "AXWindow", title: "Weekly sync | Microsoft Teams", children: [
                WindowElement(role: "AXOutline", label: "Participants", children: [
                    WindowElement(role: "AXRow", label: "In this meeting (\(joined.count))", children: [text("In this meeting")] + joined.map(row)),
                    WindowElement(role: "AXRow", label: "Others invited (\(invited.count))", children: [text("Others invited")] + invited.map(row))
                ])
            ])
        ]
    }

    private static func table(_ people: [String]) -> WindowElement {
        WindowElement(role: "AXScrollArea", children: [WindowElement(role: "AXTable", children: people.map(row))])
    }

    private static func row(_ name: String) -> WindowElement {
        WindowElement(role: "AXRow", children: [WindowElement(role: "AXCell", children: [WindowElement(role: "AXImage"), text(name)])])
    }

    private static func text(_ value: String) -> WindowElement {
        WindowElement(role: "AXStaticText", value: value)
    }
}
