import AppKit
import CoreGraphics
import Synchronization

// An active session event tap, which needs Accessibility, on its own thread so a busy main thread never holds up typing.
final class ShortcutTap: Sendable {
    struct Fire: Sendable {
        let target: SidedShortcuts.Target
        let flags: NSEvent.ModifierFlags
        let at: TimeInterval
    }

    // CoreFoundation's ports and run loop sources may be used from any thread.
    private struct Port: @unchecked Sendable {
        let port: CFMachPort
        let source: CFRunLoopSource
    }

    private struct State {
        var shortcuts = SidedShortcuts()
        var port: Port?
    }

    private let state = Mutex(State())
    private let onFire: @Sendable (Fire) -> Void
    private let loop = TapThread()

    init(onFire: @escaping @Sendable (Fire) -> Void) {
        self.onFire = onFire
    }

    func set(_ entries: [SidedShortcuts.Entry]) {
        state.withLock { $0.shortcuts.entries = entries }
    }

    // False when macOS refuses the tap, which it does without Accessibility.
    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        return state.withLock { state in
            if state.port != nil { return true }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<ShortcutTap>.fromOpaque(context).takeUnretainedValue()
                    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: context
            ), let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return false }
            let tapPort = Port(port: port, source: source)
            loop.add(tapPort.source)
            state.port = tapPort
            return true
        }
    }

    func stop() {
        state.withLock { state in
            guard let tapPort = state.port else { return }
            CGEvent.tapEnable(tap: tapPort.port, enable: false)
            CFRunLoopSourceInvalidate(tapPort.source)
            CFMachPortInvalidate(tapPort.port)
            state.port = nil
        }
    }

    // Privacy: only the key code and modifier flags are read, to match Narrari's own shortcuts; nothing is kept or logged,
    // and every other event goes on untouched.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reenable(after: type)
            return false
        case .keyDown, .keyUp:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let decision = state.withLock {
                $0.shortcuts.decide(
                    isDown: type == .keyDown, keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                    flags: flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
            }
            switch decision {
            case .pass: return false
            case .swallow: return true
            case .fire(let target):
                onFire(Fire(target: target, flags: flags, at: ProcessInfo.processInfo.systemUptime))
                return true
            }
        default:
            return false
        }
    }

    private func reenable(after type: CGEventType) {
        state.withLock { if let tapPort = $0.port { CGEvent.tapEnable(tap: tapPort.port, enable: true) } }
        if type == .tapDisabledByTimeout { Log.event("shortcut-tap-reenabled-timeout") } else { Log.event("shortcut-tap-reenabled-user-input") }
    }
}

// One thread for the tap's whole life; a port keeps its run loop waiting while no tap is on it.
private final class TapThread: Sendable {
    private let loop: Mutex<CFRunLoop?> = Mutex(nil)

    func add(_ source: CFRunLoopSource) {
        let runLoop = loop.withLock { current in
            if let current { return current }
            let started = Self.start()
            current = started
            return started
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    private static func start() -> CFRunLoop {
        let ready = DispatchSemaphore(value: 0)
        let handoff = Mutex<CFRunLoop?>(nil)
        let thread = Thread {
            handoff.withLock { $0 = CFRunLoopGetCurrent() }
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "Narrari shortcuts"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        guard let runLoop = handoff.withLock({ $0 }) else { preconditionFailure("the thread signals only once its run loop is set") }
        return runLoop
    }
}
