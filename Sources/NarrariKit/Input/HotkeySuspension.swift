import Foundation

// Held while a settings field records a shortcut. Ending it, or letting it go, gives the hotkeys back.
@MainActor
public final class HotkeySuspension {
    private weak var monitor: HotkeyMonitor?

    init(monitor: HotkeyMonitor) {
        self.monitor = monitor
    }

    public func end() {
        monitor?.resume()
        monitor = nil
    }

    isolated deinit {
        end()
    }
}
