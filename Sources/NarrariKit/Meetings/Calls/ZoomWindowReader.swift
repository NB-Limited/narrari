import Foundation

// Zoom's participants panel, docked or on its own, is titled "Participants (3)" and lists one row per person, the name
// as the row's first text with labels such as "(Host, me)". Names are read only while that panel is open.
struct ZoomWindowReader: CallWindowReader {
    let apps = ["us.zoom.xos"]
    let needsAssistiveMode = false
    let unread: StaticString = "zoom-window-unread"

    func names(in windows: [WindowElement]) -> [String]? {
        windows.lazy.compactMap { $0.first { $0.starts(with: "Participants") } }.first?.rowTexts
    }
}
