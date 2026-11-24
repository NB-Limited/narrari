import NarrariKit
import SwiftUI

struct MeetingsSidebar: View {
    @Bindable var library: MeetingLibrary
    let session: MeetingSession
    let isPermissionMissing: Bool
    let isSearchFocused: FocusState<Bool>.Binding
    let onImport: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextInput(
                label: "Search meetings", text: $library.searchText, placeholder: "Search",
                leadingSymbol: "magnifyingglass", focus: isSearchFocused
            )
            .padding(EdgeInsets(top: Space.s2, leading: Space.s14, bottom: Space.s10, trailing: Space.s14))
            .task(id: library.searchText) { await library.search() }
            list
            Rectangle().fill(Color.rule).frame(height: ControlMetrics.edge)
            VStack(alignment: .leading, spacing: 0) {
                if let error = library.importError {
                    ImportNotice(message: error, onDismiss: library.dismissImportError)
                }
                Button { Task { await session.toggle() } } label: {
                    Label(session.isMeetingUnderWay ? "Stop recording" : "Record a meeting", systemImage: "record.circle")
                        .labelStyle(NavLabelStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(RowButtonStyle())
                SidebarRow(title: "Import a recording", symbol: "square.and.arrow.down", shortcut: "⌘O", action: onImport)
                SettingsRowButton(isPermissionMissing: isPermissionMissing, action: onSettings)
            }
            .padding(Space.s8)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let hits = library.hits {
                        Text(hits.isEmpty ? "No meetings match" : hits.count == 1 ? "1 meeting" : "\(hits.count) meetings")
                            .font(Typeface.small)
                            .foregroundStyle(Color.muted)
                            .padding(EdgeInsets(top: Space.s4, leading: Space.s8, bottom: Space.s10, trailing: Space.s8))
                        rows(library.visible)
                    } else if library.hasLoaded, library.entries.isEmpty {
                        Text("No meetings yet")
                            .font(Typeface.small)
                            .foregroundStyle(Color.muted)
                            .padding(EdgeInsets(top: Space.s10, leading: Space.s8, bottom: Space.s10, trailing: Space.s8))
                    } else {
                        ForEach(library.groups) { group in
                            FolderHead(group: group, isOpen: !library.closedFolders.contains(group.name)) { library.toggleFolder(group.name) }
                            if !library.closedFolders.contains(group.name) { rows(group.entries) }
                        }
                    }
                }
                .padding(.horizontal, Space.s8)
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: library.moveSelection(by: -1)
                case .down: library.moveSelection(by: 1)
                default: return
                }
                if let selection = library.selection { proxy.scrollTo(selection) }
            }
            .onDeleteCommand {
                guard case .meeting(let id) = library.selection, library.canDelete(id) else { return }
                library.pendingDeletion = id
            }
            .onCopyCommand {
                guard let text = library.copyText else { return [] }
                return [NSItemProvider(object: text as NSString)]
            }
            .accessibilityLabel("Meetings")
        }
    }

    private func rows(_ entries: [MeetingLibrary.Entry]) -> some View {
        ForEach(entries) { entry in
            MeetingRow(entry: entry, library: library, session: session, isSelected: entry.id == library.selection) {
                library.selection = entry.id
            }
            .padding(.bottom, WindowMetrics.itemGap)
            .id(entry.id)
        }
    }
}

private struct FolderHead: View {
    let group: MeetingLibrary.Group
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.s4) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: Symbol.disclosure, weight: .semibold))
                    .frame(width: Symbol.disclosure)
                Text(group.name).lineLimit(1)
                Spacer(minLength: Space.s8)
                Text("\(group.entries.count)").fontWeight(.regular).monospacedDigit()
            }
            .font(Typeface.label)
            .foregroundStyle(Color.muted)
            .padding(EdgeInsets(top: Space.s10, leading: Space.s8, bottom: Space.s4, trailing: Space.s8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onKeyPress(keys: [.space, .return]) { _ in
            onToggle()
            return .handled
        }
        .accessibilityLabel("\(group.name), \(group.entries.count)")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
    }
}

// A meeting in the list: when, its title, then who was in it, where a search hit, or what it is waiting for.
struct MeetingRow: View {
    let entry: MeetingLibrary.Entry
    let library: MeetingLibrary
    let session: MeetingSession
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.itemGap) {
            switch entry {
            case .meeting(let meeting, _): content(meeting)
            case .unreadable(let folder): unreadable(folder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WindowMetrics.itemPadding)
        .padding(.horizontal, Space.s8)
        .background(isSelected || isHovered ? Color.selectionFill : .clear, in: RoundedRectangle(cornerRadius: Radius.listItem))
        .contentShape(RoundedRectangle(cornerRadius: Radius.listItem))
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }

    @ViewBuilder private func content(_ meeting: Meeting) -> some View {
        HStack(spacing: Space.s4) {
            Text(MeetingFormat.time(meeting.startedAt, now: .now)).lineLimit(1)
            Spacer(minLength: Space.s8)
            if meeting.pinned {
                Image(systemName: "pin.fill").font(.system(size: MeetingWindowMetrics.pinMark)).accessibilityLabel("Pinned")
            }
            if !meeting.state.isTakingAudio {
                Text(MeetingFormat.length(milliseconds: meeting.durationMs))
            }
        }
        .font(Typeface.label)
        .foregroundStyle(Color.muted)
        Text(Marked.text(MeetingFormat.title(meeting), query: library.searchText))
            .font(Typeface.body)
            .foregroundStyle(meeting.title.isEmpty ? Color.muted : Color.ink)
            .lineLimit(1)
        if let state = library.state(of: meeting) {
            StateLine(state: state, session: session)
        } else if let excerpt = library.excerpt(of: meeting.id) {
            Text(Marked.text(excerpt, query: library.searchText))
                .font(Typeface.meta)
                .foregroundStyle(Color.ink2)
                .lineLimit(2)
        } else {
            let people = MeetingFormat.listedPeople(of: meeting)
            if !people.isEmpty {
                Text(people).font(Typeface.meta).foregroundStyle(Color.muted).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func unreadable(_ folder: URL) -> some View {
        Text(MeetingFormat.folderDate(folder).map { MeetingFormat.time($0, now: .now) } ?? "")
            .font(Typeface.label)
            .foregroundStyle(Color.muted)
        Text("Unreadable meeting").font(Typeface.body).foregroundStyle(Color.ink2).lineLimit(1)
        Text(folder.lastPathComponent).font(Typeface.meta).foregroundStyle(Color.muted).lineLimit(1).truncationMode(.middle)
    }
}

private struct StateLine: View {
    let state: MeetingLibrary.RowState
    let session: MeetingSession

    var body: some View {
        Group {
            switch state {
            case .recording:
                TimelineView(.periodic(from: .now, by: MeetingMetrics.timerTick)) { _ in
                    let time = MeetingSurfaces.elapsedText(seconds: session.recordedSeconds)
                    Label(session.state == .paused ? "Paused, \(time)" : "Recording, \(time)", systemImage: "record.circle")
                }
            case .working(let verb):
                Label {
                    Text(verb)
                } icon: {
                    LoadingRadio(colour: .ink2, size: Symbol.note, lineWidth: ControlMetrics.focusRing)
                }
            case .importing: Label("Importing", systemImage: "square.and.arrow.down")
            case .processing: Label("Processing", systemImage: "hourglass")
            case .failed(let reason): Label(reason, systemImage: "exclamationmark.circle")
            }
        }
        .labelStyle(TightLabelStyle())
        .font(Typeface.meta)
        .foregroundStyle(Color.ink2)
        .lineLimit(1)
        .padding(.top, MeetingWindowMetrics.stateTop)
    }
}

// Why the last recording was not imported; it stays until dismissed or the next import.
private struct ImportNotice: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            FormError(message: message).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.icon)
                .accessibilityLabel("Dismiss")
                .iconLabel("Dismiss")
        }
        .padding(EdgeInsets(top: Space.s4, leading: Space.s8, bottom: Space.s8, trailing: 0))
        .onAppear { AccessibilityNotification.Announcement(message).post() }
    }
}

// A search hit on a Pressed fill in Ink, underlined, in the list and on the page.
enum Marked {
    static func text(_ text: String, query: String) -> AttributedString {
        var marked = AttributedString(text)
        var rest = text[...]
        while case let part = String(rest), let range = MeetingSearch.range(of: query, in: part) {
            let lower = rest.index(rest.startIndex, offsetBy: part.distance(from: part.startIndex, to: range.lowerBound))
            let upper = rest.index(lower, offsetBy: part.distance(from: range.lowerBound, to: range.upperBound))
            if let start = AttributedString.Index(lower, within: marked), let end = AttributedString.Index(upper, within: marked) {
                marked[start..<end].backgroundColor = .pressedFill
                marked[start..<end].foregroundColor = .ink
                marked[start..<end].inlinePresentationIntent = .stronglyEmphasized
                marked[start..<end].underlineStyle = Text.LineStyle(pattern: .solid, color: .ink)
            }
            rest = text[upper...]
        }
        return marked
    }
}
