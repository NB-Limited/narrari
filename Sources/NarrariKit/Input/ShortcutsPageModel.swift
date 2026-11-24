import Foundation
import Observation

// The Shortcuts page: every key Narrari listens for, recorded in place.
@MainActor
@Observable
public final class ShortcutsPageModel {
    public enum ShortcutField: Sendable, Hashable {
        case dictation
        case cleanupToggle
        case live(LiveShortcut)
    }

    private static let holdThresholds: [Double] = [0.3, 0.4, 0.5, 0.6, 0.8, 1.0]

    public private(set) var recording: ShortcutField?
    public private(set) var shortcutErrors: [ShortcutField: String] = [:]

    public var hotkeyKeyCode: Int { settings[DictationSettings.hotkeyKeyCode] }
    public var cleanupToggle: Shortcut {
        Shortcut(keyCode: settings[DictationSettings.cleanupToggleKeyCode], modifiers: settings[DictationSettings.cleanupToggleModifiers])
    }
    // A cleared shortcut has no entry.
    public var liveShortcuts: [LiveShortcut: Shortcut] {
        Dictionary(uniqueKeysWithValues: LiveShortcut.allCases.compactMap { live in
            live.shortcut(in: settings.store).map { (live, $0) }
        })
    }
    public var holdThreshold: Double {
        get { settings[DictationSettings.holdThreshold] }
        set { settings[DictationSettings.holdThreshold] = newValue }
    }

    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let sidedState: @MainActor () -> SidedShortcutState
    @ObservationIgnored private let suspendHotkeys: @MainActor () -> HotkeySuspension?
    @ObservationIgnored private var suspension: HotkeySuspension?

    public init(
        settings: SettingsMirror,
        suspendHotkeys: @escaping @MainActor () -> HotkeySuspension? = { nil },
        sidedState: @escaping @MainActor () -> SidedShortcutState = { .working }
    ) {
        self.settings = settings
        self.sidedState = sidedState
        self.suspendHotkeys = suspendHotkeys
    }

    public var hotkeyName: String { HotkeyName.name(of: hotkeyKeyCode) }

    public var sidedProblem: String? {
        guard sidedState() == .notWorking else { return nil }
        return "Shortcuts with a right-hand key are not working: macOS did not let Narrari watch the keyboard. "
            + "Check that Narrari is allowed under Accessibility on the Permissions page, then quit and reopen Narrari."
    }

    public func isNotWorking(_ field: ShortcutField) -> Bool {
        let shortcut: Shortcut? = switch field {
        case .dictation: nil
        case .cleanupToggle: cleanupToggle
        case .live(let live): liveShortcuts[live]
        }
        return sidedProblem != nil && shortcut?.isSided == true
    }

    public var holdThresholdOptions: [Double] {
        Self.holdThresholds.including(holdThreshold, inOrder: <)
    }

    public func beginRecording(_ field: ShortcutField) {
        shortcutErrors[field] = nil
        recording = field
        if suspension == nil { suspension = suspendHotkeys() }
    }

    public func endRecording() {
        guard recording != nil else { return }
        recording = nil
        suspension?.end()
        suspension = nil
    }

    public func record(modifierKey keyCode: Int) {
        guard ModifierKey.supportedKeyCodes.contains(keyCode) else { return refuseKeyForDictation() }
        settings[DictationSettings.hotkeyKeyCode] = keyCode
        shortcutErrors[.dictation] = nil
        endRecording()
    }

    public func refuseKeyForDictation() {
        shortcutErrors[.dictation] = "Use a modifier key on its own: ⌘, ⌥, ⌃ or ⇧ on either side, or fn."
        endRecording()
    }

    public func record(_ shortcut: Shortcut, for field: ShortcutField) {
        defer { endRecording() }
        if let problem = problem(with: shortcut, for: field) {
            shortcutErrors[field] = problem
            return
        }
        shortcutErrors[field] = nil
        switch field {
        case .cleanupToggle:
            settings[DictationSettings.cleanupToggleKeyCode] = shortcut.keyCode
            settings[DictationSettings.cleanupToggleModifiers] = shortcut.modifiers
        case .live(let live):
            live.store(shortcut, in: settings.store)
        case .dictation:
            break
        }
    }

    public func clear(_ live: LiveShortcut) {
        live.store(nil, in: settings.store)
        shortcutErrors[.live(live)] = nil
    }

    private func problem(with shortcut: Shortcut, for field: ShortcutField) -> String? {
        if shortcut.isEscape { return "Escape stops a dictation, so it can't be used here. Choose another key." }
        guard shortcut.hasCommandOptionOrControl else { return "Add ⌘, ⌥ or ⌃ to the key, such as ⌘E." }
        let taken = [(field: ShortcutField.cleanupToggle, shortcut: cleanupToggle, use: "already turns clean-up on or off")]
            + liveShortcuts.map { (field: .live($0.key), shortcut: $0.value, use: Self.use(of: $0.key)) }
        if let clash = taken.first(where: { $0.field != field && $0.shortcut.clashes(with: shortcut) }) {
            return "\(HotkeyName.name(of: clash.shortcut)) \(clash.use). Choose another."
        }
        return nil
    }

    private static func use(of live: LiveShortcut) -> String {
        switch live {
        case .mode: "is already the mode hotkey"
        case .openWindow: "already opens Narrari"
        case .pasteLast: "already pastes the last dictation"
        case .meeting: "already starts or stops a meeting"
        case .openSettings: "already opens Settings"
        }
    }
}
