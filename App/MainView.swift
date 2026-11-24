import NarrariKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    let route: MainRoute
    let library: HistoryLibrary
    let meetings: MeetingPageContext
    let fileJob: FileJob
    let playback: AudioPlayback
    let permissions: Permissions
    let settings: SettingsModels
    let speechModel: () -> ModelState
    let onAbout: () -> Void
    let onTranscribeFile: () -> Void
    let onDropFiles: ([URL]) -> Void
    let onImport: () -> Void
    let onDropRecordings: ([URL]) -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var isDropTargeted = false
    @State private var isEscapeTaken = false
    @State private var isReaderDetailsOpen = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: WindowMetrics.sidebarWidth)
                .background(Color.sidebarGround)
            Rectangle()
                .fill(Color.rule)
                .frame(width: ControlMetrics.edge)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.surface)
        }
        .ignoresSafeArea()
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Radius.window)
                    .strokeBorder(Color.ink, lineWidth: WindowMetrics.dropLine)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            route.list == .meetings ? onDropRecordings(urls) : onDropFiles(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .background(KeyCommands(
            route: route, isSearchFocused: $isSearchFocused, isEscapeTaken: isEscapeTaken,
            onOpenFile: { route.list == .meetings ? onImport() : onTranscribeFile() }
        ))
        .onPreferenceChange(EscapeTakenKey.self) { isEscapeTaken = $0 }
        .focusEffectDisabled()
    }

    @ViewBuilder private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: WindowMetrics.trafficLightRow)
            switch route.page {
            case .settings(let section):
                SettingsSidebar(
                    selection: section, back: route.list == .meetings ? "Meetings" : "Dictations", isPermissionMissing: !permissions.isComplete,
                    onSelect: { route.page = $0.map { .settings($0) } ?? route.list }, onAbout: onAbout
                )
            case .history, .meetings:
                SegmentedControl(
                    label: "Show", selection: Binding(get: { route.page }, set: { route.page = $0 }),
                    segments: [(.history, "Dictations"), (.meetings, "Meetings")], segmentWidth: MeetingWindowMetrics.switchSegment
                )
                .padding(EdgeInsets(top: Space.s2, leading: Space.s14, bottom: Space.s10, trailing: Space.s14))
                listSidebar
            }
        }
    }

    @ViewBuilder private var listSidebar: some View {
        if route.page == .meetings {
            MeetingsSidebar(
                library: meetings.library, session: meetings.session, isPermissionMissing: !permissions.isComplete,
                isSearchFocused: $isSearchFocused, onImport: onImport, onSettings: { route.page = route.settingsForList }
            )
        } else {
            HistorySidebar(
                library: library,
                playback: playback,
                fileJob: fileJob,
                isPermissionMissing: !permissions.isComplete,
                isSearchFocused: $isSearchFocused,
                onSelect: { route.page = .history },
                onTranscribeFile: onTranscribeFile,
                onSettings: { route.page = route.settingsForList }
            )
        }
    }

    @ViewBuilder private var page: some View {
        switch route.page {
        case .settings(let section):
            VStack(spacing: 0) {
                Color.clear.frame(height: WindowMetrics.toolbarHeight)
                section.page(settings)
            }
        case .history:
            if let entry = library.selected, let running = fileJob.running, running.id == entry.id {
                FileProgressPage(entry: entry, running: running, apps: library.apps, onCancel: fileJob.cancel)
            } else if let entry = library.selected {
                ReaderPage(entry: entry, library: library, playback: playback, isDetailsOpen: $isReaderDetailsOpen)
                    .id(entry.id)
            } else if library.load == .idle, !library.entries.isEmpty {
                NoResultsPage(query: library.searchText)
            } else if library.load == .idle {
                EmptyHistoryPage(prompt: EmptyHistory(model: speechModel(), hotkey: settings.shortcuts.hotkeyName, kept: settings.history.keptLine))
            }
        case .meetings:
            switch meetings.library.selected {
            case .meeting(let meeting, _)? where meeting.state == .importing:
                ImportingMeetingPage()
            case .meeting(let meeting, _)?:
                MeetingPageView(meeting: meeting, context: meetings).id(meeting.id)
            case .unreadable(let folder)?:
                UnreadableMeetingPage(folder: folder)
            case nil:
                if meetings.library.load == .idle, meetings.library.entries.isEmpty {
                    EmptyMeetingsPage(
                        retentionDays: meetings.library.retentionDays, onRecord: { Task { await meetings.session.toggle() } }, onImport: onImport
                    )
                } else if meetings.library.hits?.isEmpty == true {
                    NoMeetingResultsPage(query: meetings.library.searchText)
                }
            }
        }
    }
}

// Window-wide keys, on every page: Command F to search, Command O to transcribe a file or import a recording, Escape to leave settings.
private struct KeyCommands: View {
    let route: MainRoute
    let isSearchFocused: FocusState<Bool>.Binding
    let isEscapeTaken: Bool
    let onOpenFile: () -> Void

    var body: some View {
        ZStack {
            Button("Search") {
                if route.isSettings { route.page = route.list }
                isSearchFocused.wrappedValue = true
            }
            .keyboardShortcut("f")
            Button("Open a file", action: onOpenFile)
                .keyboardShortcut("o")
            Button("Back") { route.page = route.list }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!route.isSettings || isEscapeTaken)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
