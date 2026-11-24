import AppKit
import NarrariKit
import SwiftUI

// Everything the meeting page needs besides the meeting.
struct MeetingPageContext {
    let library: MeetingLibrary
    let session: MeetingSession
    let playback: AudioPlayback
    let apps: AppDirectory
    // Read from the folder each time, so a template added on disk is offered at once.
    let templates: @MainActor () -> [(id: String, title: String)]
    let summaryModels: SummaryModels
    let makePage: @MainActor (Meeting, String) -> MeetingPage
}

struct MeetingPageView: View {
    let context: MeetingPageContext
    @State private var page: MeetingPage
    @State private var followsLive = true
    @State private var scrollPosition = ScrollPosition()
    @State private var offset: CGFloat = 0
    @State private var tabOffsets: [MeetingPage.Tab: CGFloat] = [:]

    init(meeting: Meeting, context: MeetingPageContext) {
        self.context = context
        _page = State(initialValue: context.makePage(meeting, context.library.searchText))
    }

    private var library: MeetingLibrary { context.library }

    var body: some View {
        let isRecording = page.meeting.id == context.session.recordingID
        VStack(spacing: 0) {
            MeetingToolbar(page: page, context: context, isRecording: isRecording)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        head(isRecording: isRecording)
                        if let steps = page.steps {
                            MeetingSteps(rows: steps, page: page)
                                .padding(.top, MeetingWindowMetrics.stepsTop)
                        }
                        MeetingTabs(page: page, context: context, isRecording: isRecording, scroll: proxy, followsLive: followsLive)
                            .padding(.top, MeetingWindowMetrics.tabsTop)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: Space.s4, leading: Space.s36, bottom: Space.s22, trailing: Space.s36))
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ScrollPlace.self, of: ScrollPlace.init) { old, new in
                    offset = new.offset
                    if new.offset != old.offset { followsLive = new.isAtEnd }
                }
                .onChange(of: page.tab) { old, new in
                    tabOffsets[old] = offset
                    scrollPosition.scrollTo(y: tabOffsets[new] ?? 0)
                }
            }
            if !isRecording {
                if page.hasAudio {
                    AudioBar(playback: context.playback)
                } else if page.meeting.state != .recording {
                    AudioRemovedBar(days: library.retentionDays)
                }
            }
        }
        .onChange(of: page.copyText, initial: true) { _, text in library.shownText = (page.meeting.id, text) }
        .task(id: page.meeting.id) {
            await page.load()
            context.playback.load(page.audio, expectedDuration: Double(page.meeting.durationMs) / 1000)
        }
        .onChange(of: library.selected) { _, entry in
            guard case .meeting(let meeting, _)? = entry, meeting != page.meeting else { return }
            Task {
                await page.load()
                context.playback.load(page.audio, expectedDuration: Double(page.meeting.durationMs) / 1000)
            }
        }
    }

    @ViewBuilder private func head(isRecording: Bool) -> some View {
        let meeting = page.meeting
        HStack(spacing: Space.s16) {
            meta(meeting, isRecording: isRecording)
                .accessibilityElement(children: .combine)
            language(isRecording: isRecording)
        }
        .font(Typeface.small)
        .foregroundStyle(Color.muted)
        .lineLimit(1)
        MeetingTitle(meeting: meeting, library: library)
            .padding(.top, MeetingWindowMetrics.titleTop)
        if let people = MeetingFormat.pagePeople(of: meeting) {
            Text(people)
                .font(Typeface.small)
                .foregroundStyle(Color.ink2)
                .padding(.top, MeetingWindowMetrics.peopleTop)
        }
        attention(meeting)
    }

    private func meta(_ meeting: Meeting, isRecording: Bool) -> some View {
        HStack(spacing: Space.s16) {
            if isRecording {
                RecordingMeta(session: context.session)
            } else {
                Text(MeetingFormat.when(meeting.startedAt, now: .now)).fontWeight(.semibold).foregroundStyle(Color.ink2)
                Text(MeetingFormat.length(milliseconds: meeting.durationMs))
            }
            if !meeting.app.isEmpty {
                let app = context.apps.app(for: meeting.app)
                HStack(spacing: Space.s4) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: MeetingWindowMetrics.appIcon, height: MeetingWindowMetrics.appIcon)
                            .clipShape(RoundedRectangle(cornerRadius: MeetingWindowMetrics.appIconRadius))
                            .accessibilityHidden(true)
                    }
                    Text(app.name)
                }
            }
            if let folder = folderShown {
                Label(folder, systemImage: "folder").labelStyle(TightLabelStyle())
            }
        }
    }

    // At the end of the meta line, apart from it for VoiceOver; it waits like Redo summary while the steps run.
    @ViewBuilder private func language(isRecording: Bool) -> some View {
        if !isRecording, let line = page.languageLine {
            LanguageMenu(line: line, chosen: page.meeting.language) { code in Task { await page.summarise(in: code) } }
                .disabled(page.isProcessing || !page.canRedoSummary)
        }
    }

    // The folder, only when it says more than the app's name.
    private var folderShown: String? {
        guard case .meeting(_, let folder)? = library.entries.first(where: { $0.id == .meeting(page.meeting.id) }) else { return nil }
        let appName = page.meeting.app.isEmpty ? "" : context.apps.name(for: page.meeting.app)
        return folder == appName ? nil : folder
    }

    @ViewBuilder private func attention(_ meeting: Meeting) -> some View {
        let notes = meeting.soundNotes + [
            meeting.state == .recovered ? "Recovered after Narrari quit." : nil,
            meeting.stop == .lowDisk ? "Stopped because the disk was nearly full." : nil,
            meeting.stop == .sleep ? "Stopped when the Mac went to sleep." : nil
        ].compactMap { $0 }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: Space.s4) {
                ForEach(notes, id: \.self) { note in
                    HStack(spacing: Space.s8) {
                        Label(note, systemImage: "exclamationmark.circle")
                            .labelStyle(NoteLabelStyle())
                        if meeting.systemSound == .unheard, note == notes.first {
                            Button("Open System Audio Settings") { Permissions.openSystemAudioSettings() }
                                .buttonStyle(.secondary)
                        }
                    }
                }
            }
            .font(Typeface.small)
            .foregroundStyle(Color.ink2)
            .padding(.top, MeetingWindowMetrics.attentionTop)
        }
    }
}

// Only a scroll changes whether the page follows the end; content growing under it does not.
private struct ScrollPlace: Equatable {
    let offset: CGFloat
    let isAtEnd: Bool

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        isAtEnd = offset + geometry.containerSize.height >= geometry.contentSize.height - MeetingWindowMetrics.endSlack
    }
}

private struct NoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: MeetingWindowMetrics.noteGap) {
            configuration.icon.font(.system(size: Symbol.note))
            configuration.title
        }
    }
}

// "Recording, 12:04" after a still Ink dot; "Paused, 12:04" with no dot.
private struct RecordingMeta: View {
    let session: MeetingSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: MeetingMetrics.timerTick)) { _ in
            let time = MeetingSurfaces.elapsedText(seconds: session.recordedSeconds)
            HStack(spacing: Space.s4 + Space.s2) {
                if session.state != .paused {
                    Circle().fill(Color.ink).frame(width: MeetingWindowMetrics.recordingDot, height: MeetingWindowMetrics.recordingDot)
                        .accessibilityHidden(true)
                }
                Text(session.state == .paused ? "Paused, \(time)" : "Recording, \(time)")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.ink2)
                    .monospacedDigit()
            }
        }
    }
}

// The title in the Title type; a click or Return renames it in place.
private struct MeetingTitle: View {
    let meeting: Meeting
    let library: MeetingLibrary

    @State private var draft: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let shown = MeetingFormat.title(meeting)
        if let draft {
            TextField("Title", text: Binding(get: { draft }, set: { self.draft = $0 }))
                .textFieldStyle(.plain)
                .font(Typeface.title)
                .foregroundStyle(Color.ink)
                .tint(Color.ink)
                .focused($isFieldFocused)
                .onAppear { isFieldFocused = true }
                .onSubmit { commit(draft) }
                .onExitCommand { self.draft = nil }
                .onChange(of: isFieldFocused) { _, focused in if !focused { commit(draft) } }
                .accessibilityLabel("Title")
        } else {
            Button { draft = meeting.title } label: {
                Text(shown)
                    .font(Typeface.title)
                    .lineSpacing(Typeface.titleLineSpacing)
                    .foregroundStyle(meeting.title.isEmpty ? Color.muted : Color.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shown)
            .accessibilityHint("Renames the meeting")
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func commit(_ text: String) {
        guard draft != nil else { return }
        draft = nil
        Task { await library.rename(meeting.id, to: text) }
    }
}

private struct AudioRemovedBar: View {
    let days: Int

    var body: some View {
        HStack(spacing: Space.s4 + Space.s2) {
            Image(systemName: "waveform.slash").font(.system(size: Symbol.note))
            Text("Audio removed after \(HistoryPageModel.title(forDays: days))")
        }
        .font(Typeface.small)
        .foregroundStyle(Color.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ControlMetrics.iconButton)
        .padding(EdgeInsets(top: Space.s12, leading: Space.s36, bottom: Space.s16, trailing: Space.s36))
        .accessibilityElement(children: .combine)
    }
}

private struct MeetingToolbar: View {
    let page: MeetingPage
    let context: MeetingPageContext
    let isRecording: Bool

    @State private var folderAnchor = Anchor()
    @FocusState private var isConfirmFocused: Bool

    private var library: MeetingLibrary { context.library }

    var body: some View {
        HStack(spacing: Space.s2) {
            Spacer(minLength: 0)
            if library.pendingDeletion == page.meeting.id {
                confirmation
            } else if isRecording {
                recordingActions
            } else {
                actions
            }
        }
        .padding(.horizontal, Space.s12)
        .frame(height: WindowMetrics.toolbarHeight)
    }

    @ViewBuilder private var recordingActions: some View {
        let session = context.session
        let isPaused = session.state == .paused
        Button { isPaused ? session.resume() : session.pause() } label: {
            Image(systemName: isPaused ? "play.circle" : "pause.circle")
        }
        .buttonStyle(.icon)
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
        .iconLabel(isPaused ? "Resume recording" : "Pause recording")
        Button { Task { await session.stop() } } label: { Image(systemName: "stop.circle") }
            .buttonStyle(.icon)
            .accessibilityLabel("Stop recording")
            .iconLabel("Stop recording")
    }

    @ViewBuilder private var actions: some View {
        let meeting = page.meeting
        PlayButton(playback: context.playback, unavailable: page.hasAudio ? nil : "No audio kept")
        Button { Task { await library.togglePin(meeting.id) } } label: { Image(systemName: meeting.pinned ? "pin.fill" : "pin") }
            .buttonStyle(.icon)
            .accessibilityLabel(meeting.pinned ? "Unpin meeting" : "Pin meeting and keep its audio")
            .iconLabel(meeting.pinned ? "Unpin meeting" : "Pin meeting and keep its audio")
        Button(action: openFolders) { Image(systemName: "folder") }
            .buttonStyle(.icon)
            .background(AnchorView(anchor: folderAnchor))
            .accessibilityLabel("Move to folder")
            .iconLabel("Move to folder")
        Button { library.pendingDeletion = meeting.id } label: { Image(systemName: "trash") }
            .buttonStyle(.icon)
            .accessibilityLabel("Delete meeting")
            .iconLabel("Delete meeting", shortcut: "⌫")
    }

    @ViewBuilder private var confirmation: some View {
        let question = page.hasAudio ? "Delete this meeting and its audio?" : "Delete this meeting?"
        Text(question)
            .font(Typeface.smallMedium)
            .foregroundStyle(Color.ink)
            .padding(.trailing, Space.s8)
        Button("Cancel") { library.pendingDeletion = nil }
            .buttonStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .padding(.trailing, Space.s4)
        Button("Delete") {
            context.playback.stop()
            Task { await library.delete(page.meeting.id) }
        }
        .buttonStyle(.destructive)
        .keyboardShortcut(.defaultAction)
        .focused($isConfirmFocused)
        .onAppear {
            isConfirmFocused = true
            AccessibilityNotification.Announcement(question).post()
        }
    }

    // The folders with the current one checked, then a new one by name.
    private func openFolders() {
        guard let view = folderAnchor.view else { return }
        let id = page.meeting.id
        let current = library.entries.first { $0.id == .meeting(id) }?.folder
        let folders = library.folders
        let rows = folders.map { DropdownRow(title: $0) } + [DropdownRow(title: "New folder…")]
        Dropdown.shared.open(
            label: "Move to folder", rows: rows, chosen: folders.firstIndex { $0 == current }, from: view, alignment: .trailing
        ) { index in
            guard folders.indices.contains(index) else { return newFolder(id, from: view) }
            Task { await library.move(id, toFolder: folders[index]) }
        }
    }

    private func newFolder(_ id: UUID, from view: NSView) {
        let field = DropdownField(placeholder: "Folder name") { typed in
            let name = typed.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return [] }
            return [DropdownRow(title: "Move to “\(name)”", action: { Task { await library.move(id, toFolder: name) } })]
        }
        Task { @MainActor in Dropdown.shared.open(label: "New folder", field: field, from: view, alignment: .trailing) }
    }
}
