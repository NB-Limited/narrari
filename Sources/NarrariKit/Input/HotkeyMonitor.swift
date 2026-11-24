import AppKit
import Carbon.HIToolbox
import Observation

public enum RecordingKeys: Sendable {
    case off
    case escape
    case escapeAndCleanupToggle
}

@MainActor
public protocol HotkeySource: AnyObject {
    var onInput: ((HotkeyGesture.Input, TimeInterval) -> Void)? { get set }
    func setRecordingKeys(_ keys: RecordingKeys)
}

public enum SidedShortcutState: CaseIterable, Sendable, Equatable {
    case none
    case working
    case notWorking

    // Logged at start and on each change; narrari doctor reads it back.
    public var logName: StaticString {
        switch self {
        case .none: "shortcut-tap-off"
        case .working: "shortcut-tap-on"
        case .notWorking: "shortcut-tap-refused"
        }
    }
}

@MainActor
@Observable
public final class HotkeyMonitor: HotkeySource {
    public private(set) var sidedShortcuts = SidedShortcutState.none
    @ObservationIgnored public var onInput: ((HotkeyGesture.Input, TimeInterval) -> Void)?
    @ObservationIgnored public var onShortcut: ((LiveShortcut) -> Void)?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private var hotkey: ModifierKey?
    @ObservationIgnored private var isHotkeyDown = false
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var recordingHotkeys: [EventHotKeyRef] = []
    @ObservationIgnored private var liveHotkeys: [EventHotKeyRef] = []
    @ObservationIgnored private var cleanupToggle: Shortcut?
    @ObservationIgnored private var hotkeyHandler: EventHandlerRef?
    @ObservationIgnored private var hadAccessibility = false
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var suspensions = 0
    @ObservationIgnored private var tap: ShortcutTap?
    @ObservationIgnored private var sidedLive: [SidedShortcuts.Entry] = []
    @ObservationIgnored private var sidedToggle: SidedShortcuts.Entry?
    @ObservationIgnored private var reportedTapState: SidedShortcutState?
    @ObservationIgnored private var presses = ShortcutPresses()

    private static let hotkeySignature: OSType = 0x4E52_5249 // "NRRI"
    private static let escapeID: UInt32 = 1
    private static let cleanupToggleID: UInt32 = 2

    public init(settings: SettingsStore, permissions: Permissions) {
        self.settings = settings
        self.permissions = permissions
    }

    // The Carbon handler holds an unretained pointer to this object, so it must go before the object does.
    isolated deinit {
        unregisterRecordingKeys()
        unregisterLiveHotkeys()
        monitors.forEach { NSEvent.removeMonitor($0) }
        tap?.stop()
        following?.cancel()
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
    }

    public func start() {
        tap = ShortcutTap { [weak self] fire in
            Task { @MainActor in self?.fired(fire) }
        }
        readHotkey()
        installHotkeyHandler()
        registerLiveHotkeys()
        installMonitors()
        hadAccessibility = permissions.isAccessibilityAllowed
        followAccessibility()
        let liveKeys = LiveShortcut.allCases.flatMap { [$0.keyCode.key, $0.modifiers.key] }
        let toggleKeys = [DictationSettings.cleanupToggleKeyCode.key, DictationSettings.cleanupToggleModifiers.key]
        let updates = SettingsChanges.updates(of: Set([DictationSettings.hotkeyKeyCode.key] + liveKeys + toggleKeys))
        following = Task { [weak self] in
            for await _ in updates {
                self?.readHotkey()
                self?.registerLiveHotkeys()
            }
        }
    }

    public var isSuspended: Bool { suspensions > 0 }

    // While a settings field records a new shortcut, the keys pressed must not dictate or switch modes.
    // The hotkeys return once every suspension has ended or been released, so a lost one can't keep them off.
    public func suspend() -> HotkeySuspension {
        suspensions += 1
        if suspensions == 1 { suspensionChanged() }
        return HotkeySuspension(monitor: self)
    }

    func resume() {
        suspensions -= 1
        if suspensions == 0 { suspensionChanged() }
    }

    private func suspensionChanged() {
        isHotkeyDown = false
        presses = ShortcutPresses()
        registerLiveHotkeys()
    }

    private func readHotkey() {
        hotkey = ModifierKey(keyCode: settings.value(DictationSettings.hotkeyKeyCode))
        isHotkeyDown = false
        presses = ShortcutPresses()
        if hotkey == nil { Log.failure("hotkey-not-a-modifier") }
    }

    public func setRecordingKeys(_ keys: RecordingKeys) {
        unregisterRecordingKeys()
        defer { refreshTap() }
        guard keys != .off, permissions.isAccessibilityAllowed else { return }
        let held = hotkey?.carbonModifier ?? 0
        for modifiers in Set([0, held]) {
            let isRegistered = registerRecordingKey(UInt32(kVK_Escape), modifiers, id: Self.escapeID)
            if !isRegistered { Log.failure("escape-hotkey") }
        }
        guard keys == .escapeAndCleanupToggle else { return }
        let toggle = Shortcut.cleanupToggle(in: settings)
        cleanupToggle = toggle
        if toggle.isSided {
            sidedToggle = SidedShortcuts.Entry(toggle, .cleanupToggle, alsoWith: hotkey?.flag ?? [])
            return
        }
        let toggleModifiers = UInt32(clamping: toggle.carbonModifiers)
        for modifiers in Set([toggleModifiers, toggleModifiers | held]) {
            let isRegistered = registerRecordingKey(UInt32(UInt16(clamping: toggle.keyCode)), modifiers, id: Self.cleanupToggleID)
            if !isRegistered { Log.failure("cleanup-toggle-hotkey") }
        }
    }

    private func unregisterRecordingKeys() {
        recordingHotkeys.forEach { UnregisterEventHotKey($0) }
        recordingHotkeys = []
        cleanupToggle = nil
        sidedToggle = nil
    }

    // Shortcuts with a side go to the key tap, since Carbon cannot tell sides apart; the rest stay with Carbon.
    public func registerLiveHotkeys() {
        unregisterLiveHotkeys()
        sidedLive = LiveShortcut.allCases.compactMap { live in
            live.shortcut(in: settings).flatMap { $0.isSided ? SidedShortcuts.Entry($0, .live(live)) : nil }
        }
        defer { refreshTap() }
        guard !isSuspended else { return }
        for live in LiveShortcut.allCases {
            guard let shortcut = live.shortcut(in: settings), !shortcut.isSided else { continue }
            let id = Self.liveID(live)
            if let reference = register(UInt32(shortcut.keyCode), UInt32(clamping: shortcut.carbonModifiers), id: id) {
                liveHotkeys.append(reference)
            } else {
                Self.logRegisterFailure(live)
            }
        }
    }

    private var tapEntries: [SidedShortcuts.Entry] {
        isSuspended ? [] : sidedLive + [sidedToggle].compactMap { $0 }
    }

    // Accessibility is checked first so a tap is never asked for without it.
    private func refreshTap() {
        guard let tap else { return }
        tap.set(tapEntries)
        let state: SidedShortcutState
        if sidedLive.isEmpty, !Shortcut.cleanupToggle(in: settings).isSided {
            tap.stop()
            state = .none
        } else if permissions.isAccessibilityAllowed, tap.start() {
            state = .working
        } else {
            tap.stop()
            state = .notWorking
        }
        sidedShortcuts = state
        guard state != reportedTapState else { return }
        reportedTapState = state
        Log.event(state.logName)
    }

    private func fired(_ fire: ShortcutTap.Fire) {
        guard !isSuspended else { return }
        switch fire.target {
        case .live(let live):
            presses.shortcutFired(at: fire.at, isHotkeyHeld: hotkey?.isPressed(in: fire.flags) == true, isHotkeyDown: isHotkeyDown)
            onInput?(.shortcut, fire.at)
            onShortcut?(live)
        case .cleanupToggle:
            onInput?(.cleanupToggle, fire.at)
        }
    }

    private static func liveID(_ live: LiveShortcut) -> UInt32 {
        switch live {
        case .mode: 3
        case .openWindow: 4
        case .pasteLast: 5
        case .meeting: 6
        case .openSettings: 7
        }
    }

    private static func logRegisterFailure(_ live: LiveShortcut) {
        switch live {
        case .mode: Log.failure("mode-hotkey")
        case .openWindow: Log.failure("open-window-hotkey")
        case .pasteLast: Log.failure("paste-last-hotkey")
        case .meeting: Log.failure("meeting-hotkey")
        case .openSettings: Log.failure("open-settings-hotkey")
        }
    }

    private func unregisterLiveHotkeys() {
        liveHotkeys.forEach { UnregisterEventHotKey($0) }
        liveHotkeys = []
    }

    private func registerRecordingKey(_ keyCode: UInt32, _ modifiers: UInt32, id: UInt32) -> Bool {
        guard let reference = register(keyCode, modifiers, id: id) else { return false }
        recordingHotkeys.append(reference)
        return true
    }

    private func register(_ keyCode: UInt32, _ modifiers: UInt32, id: UInt32) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: Self.hotkeySignature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0, &reference)
        return status == noErr ? reference : nil
    }

    private func hotkeyPressed(_ hotkey: EventHotKeyID) -> Bool {
        guard hotkey.signature == Self.hotkeySignature else { return false }
        if let live = LiveShortcut.allCases.first(where: { Self.liveID($0) == hotkey.id }) {
            onShortcut?(live)
            return true
        }
        let input: HotkeyGesture.Input
        switch hotkey.id {
        case Self.escapeID: input = .escape
        case Self.cleanupToggleID: input = .cleanupToggle
        default: return false
        }
        onInput?(input, ProcessInfo.processInfo.systemUptime)
        return true
    }

    private func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    // Global key monitors added before the grant may stay deaf, so they are added again once it arrives.
    private func followAccessibility() {
        let isAllowed = withObservationTracking {
            permissions.isAccessibilityAllowed
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAccessibility() }
        }
        if isAllowed, !hadAccessibility {
            Log.event("accessibility-granted")
            installMonitors()
        }
        hadAccessibility = isAllowed
        refreshTap()
    }

    // Without Accessibility only modifier events arrive, so another key could never cancel a shortcut; nothing is passed on.
    private func handle(_ event: NSEvent) {
        guard permissions.isAccessibilityAllowed, !isSuspended, let hotkey else { return }
        let kind: KeyEvent.Kind
        switch event.type {
        case .flagsChanged: kind = .modifier
        case .keyDown: kind = .key
        default: return
        }
        let key = KeyEvent(kind: kind, keyCode: event.keyCode, flags: event.modifierFlags)
        let sided = SidedShortcuts(entries: sidedShortcuts == .working ? tapEntries : [])
        guard let input = Self.input(for: key, hotkey: hotkey, isHotkeyDown: isHotkeyDown, cleanupToggle: cleanupToggle, sided: sided)
        else { return }
        if input == .hotkeyDown || input == .hotkeyUp { isHotkeyDown = input == .hotkeyDown }
        guard let passed = presses.pass(input, at: event.timestamp) else { return }
        onInput?(passed, event.timestamp)
    }

    // What one key event means to the dictation gesture, or nil when it means nothing; the key tap reports its own keys.
    public static func input(
        for event: KeyEvent, hotkey: ModifierKey, isHotkeyDown: Bool, cleanupToggle: Shortcut?, sided: SidedShortcuts = SidedShortcuts()
    ) -> HotkeyGesture.Input? {
        switch event.kind {
        case .modifier where event.keyCode == hotkey.keyCode:
            let isDown = hotkey.isPressed(in: event.flags)
            guard isDown != isHotkeyDown else { return nil }
            return isDown ? .hotkeyDown : .hotkeyUp
        case .modifier:
            return ModifierKey(keyCode: Int(event.keyCode))?.isPressed(in: event.flags) == true ? .otherKey : nil
        // Holding the dictation key while pressing the toggle must not read as another key cancelling the dictation.
        case .key where cleanupToggle?.matches(keyCode: event.keyCode, flags: event.flags, alsoWith: hotkey.flag) == true:
            return nil
        case .key where sided.claims(keyCode: event.keyCode, flags: event.flags):
            return nil
        case .key:
            return .otherKey
        }
    }

    private func installHotkeyHandler() {
        guard hotkeyHandler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
                )
                guard status == noErr else { return status }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                let isOurs = MainActor.assumeIsolated { monitor.hotkeyPressed(hotkeyID) }
                return isOurs ? noErr : OSStatus(eventNotHandledErr)
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotkeyHandler
        )
        if status != noErr { Log.failure("hotkey-handler") }
    }
}

public struct KeyEvent: Sendable {
    public enum Kind: Sendable {
        case modifier
        case key
    }

    public let kind: Kind
    public let keyCode: UInt16
    public let flags: NSEvent.ModifierFlags

    public init(kind: Kind, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
    }
}

// A sided shortcut's tap report can reach the main thread before the dictation key's own press does; that press then
// belongs to the shortcut and must start no dictation.
public struct ShortcutPresses: Sendable {
    private var firedBeforePress: TimeInterval?
    private var isIgnoringPress = false

    public init() {}

    public mutating func shortcutFired(at time: TimeInterval, isHotkeyHeld: Bool, isHotkeyDown: Bool) {
        if isHotkeyHeld, !isHotkeyDown { firedBeforePress = time }
    }

    public mutating func pass(_ input: HotkeyGesture.Input, at time: TimeInterval) -> HotkeyGesture.Input? {
        switch input {
        case .hotkeyDown:
            defer { firedBeforePress = nil }
            guard let fired = firedBeforePress, time <= fired else { return input }
            isIgnoringPress = true
            return nil
        case .hotkeyUp where isIgnoringPress:
            isIgnoringPress = false
            return nil
        default:
            return input
        }
    }
}

public struct ModifierKey: Sendable {
    let keyCode: UInt16
    let deviceMask: UInt
    let carbonModifier: UInt32
    let name: String

    // Device masks tell the left and right key apart, which the plain modifier flags cannot.
    private static let known: [Int: (deviceMask: UInt, carbonModifier: Int, name: String)] = [
        54: (0x10, cmdKey, "Right ⌘"), 55: (0x08, cmdKey, "Left ⌘"),
        56: (0x02, shiftKey, "Left ⇧"), 60: (0x04, shiftKey, "Right ⇧"),
        58: (0x20, optionKey, "Left ⌥"), 61: (0x40, optionKey, "Right ⌥"),
        59: (0x01, controlKey, "Left ⌃"), 62: (0x2000, controlKey, "Right ⌃"),
        63: (NSEvent.ModifierFlags.function.rawValue, 0, "fn")
    ]

    static let supportedKeyCodes = known.keys.sorted()

    public init?(keyCode: Int) {
        guard let key = Self.known[keyCode] else { return nil }
        self.keyCode = UInt16(keyCode)
        deviceMask = key.deviceMask
        carbonModifier = UInt32(key.carbonModifier)
        name = key.name
    }

    func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.rawValue & deviceMask != 0
    }

    var flag: NSEvent.ModifierFlags {
        Shortcut.flags.first { $0.carbon == Int(carbonModifier) }?.flag ?? []
    }
}
