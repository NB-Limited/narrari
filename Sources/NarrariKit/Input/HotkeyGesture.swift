import Foundation

public struct HotkeyGesture: Sendable {
    public enum Input: Sendable, Equatable {
        case hotkeyDown
        case hotkeyUp
        case otherKey
        case shortcut
        case escape
        case cleanupToggle
        case tick
    }

    public enum DiscardCause: Sendable, Equatable {
        case escape
        case shortcutKey
        case shortcut
        case keyWhileHeld
        case tooShort
    }

    public enum Action: Sendable, Equatable {
        case begin
        case confirm
        case stop
        case discard(DiscardCause)
        case toggleCleanup
    }

    public struct Timing: Sendable, Equatable {
        public var holdThreshold: TimeInterval
        public var shortcutWindow: TimeInterval
        public var minimumRecording: TimeInterval

        public init(holdThreshold: TimeInterval, shortcutWindow: TimeInterval, minimumRecording: TimeInterval) {
            self.holdThreshold = holdThreshold
            self.shortcutWindow = shortcutWindow
            self.minimumRecording = minimumRecording
        }

        public init(settings: SettingsStore) {
            self.init(
                holdThreshold: settings.value(DictationSettings.holdThreshold),
                shortcutWindow: settings.value(DictationSettings.shortcutWindow),
                minimumRecording: settings.value(DictationSettings.minimumRecording)
            )
        }
    }

    private enum Phase: Sendable, Equatable {
        case idle
        case held(since: TimeInterval)
        case handsFree
    }

    public var timing: Timing
    private var phase = Phase.idle
    private var beganAt: TimeInterval = 0
    private var isConfirmed = false

    public init(timing: Timing) {
        self.timing = timing
    }

    var isHandsFree: Bool { phase == .handsFree }

    public mutating func handle(_ input: Input, at time: TimeInterval) -> [Action] {
        switch (input, phase) {
        case (.hotkeyDown, .idle):
            phase = .held(since: time)
            beganAt = time
            isConfirmed = false
            return [.begin]
        case (.hotkeyDown, .handsFree):
            return finish(at: time)
        case (.hotkeyUp, .held(let since)):
            if time - since >= timing.holdThreshold { return finish(at: time) }
            phase = .handsFree
            return []
        case (.otherKey, .held):
            return discard(isInShortcutWindow(at: time) ? .shortcutKey : .keyWhileHeld)
        case (.escape, .held), (.escape, .handsFree):
            return discard(.escape)
        case (.otherKey, .handsFree) where isInShortcutWindow(at: time):
            return discard(.shortcutKey)
        case (.shortcut, .held):
            return discard(.shortcut)
        case (.shortcut, .handsFree) where isInShortcutWindow(at: time):
            return discard(.shortcut)
        case (.cleanupToggle, .held), (.cleanupToggle, .handsFree):
            return [.toggleCleanup]
        case (.tick, .held), (.tick, .handsFree):
            guard !isConfirmed, !isInShortcutWindow(at: time) else { return [] }
            isConfirmed = true
            return [.confirm]
        default:
            return []
        }
    }

    public mutating func toggle(at time: TimeInterval) -> [Action] {
        guard phase == .idle else { return finish(at: time) }
        phase = .handsFree
        beganAt = time
        isConfirmed = true
        return [.begin, .confirm]
    }

    public mutating func reset() {
        phase = .idle
    }

    private func isInShortcutWindow(at time: TimeInterval) -> Bool {
        time - beganAt < timing.shortcutWindow
    }

    private mutating func discard(_ cause: DiscardCause) -> [Action] {
        phase = .idle
        return [.discard(cause)]
    }

    private mutating func finish(at time: TimeInterval) -> [Action] {
        phase = .idle
        return time - beganAt < timing.minimumRecording ? [.discard(.tooShort)] : [.stop]
    }
}
