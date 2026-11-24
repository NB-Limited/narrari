import AppKit
import NarrariKit
import SwiftUI

@MainActor
@Observable
final class MainRoute {
    enum Page: Hashable {
        case history
        case meetings
        case settings(SettingsSection)
    }

    var page = Page.history {
        didSet {
            switch page {
            case .history, .meetings: list = page
            case .settings(let section): lastSettings = section
            }
        }
    }
    // The side of the Dictations and Meetings switch last shown, where Settings goes back to.
    private(set) var list = Page.history
    // Where the Open Settings shortcut and the menu panel's Settings open.
    private(set) var lastSettings = SettingsSection.general

    // The window's own Settings row opens the page for the side it was pressed on.
    var settingsForList: Page {
        .settings(list == .meetings ? .recording : .general)
    }

    var isSettings: Bool {
        if case .settings = page { return true }
        return false
    }
}

// One window for dictations, meetings and settings. Narrari is in the Dock only while the window is open;
// closed, it is a menu bar app again.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let route = MainRoute()
    private let makeContent: (MainRoute) -> AnyView
    private let onClose: () -> Void
    private var window: NSWindow?

    private static let frameName = "MainWindow"

    init(onClose: @escaping () -> Void, content: @escaping (MainRoute) -> some View) {
        self.onClose = onClose
        makeContent = { AnyView(content($0)) }
    }

    func show(_ page: MainRoute.Page? = nil) {
        if let page { route.page = page }
        let window = window ?? makeWindow()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // The open panel comes down from the window as a sheet, limited to the files a transcription or an import reads.
    func chooseFile(then start: @escaping (URL) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileJob.fileTypes
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            start(url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        onClose()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowMetrics.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Narrari"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty compact toolbar makes the title bar 40 pt tall, so the traffic lights sit centred in the sidebar's top row.
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.contentMinSize = WindowMetrics.minimumSize
        window.backgroundColor = NSColor(named: "Window")
        window.delegate = self
        // As the content view itself, the page's own size replaces the window's limits and resizes the window.
        let hosting = NSHostingView(rootView: makeContent(route))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        let content = NSView(frame: NSRect(origin: .zero, size: WindowMetrics.defaultSize))
        hosting.frame = content.bounds
        content.addSubview(hosting)
        window.contentView = content
        let fits = window.setFrameUsingName(Self.frameName)
            && (window.screen ?? NSScreen.main).map { window.frame.width <= $0.visibleFrame.width && window.frame.height <= $0.visibleFrame.height } ?? true
        if !fits {
            window.setContentSize(WindowMetrics.defaultSize)
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        self.window = window
        return window
    }
}
