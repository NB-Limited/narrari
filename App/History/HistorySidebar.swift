import AppKit
import NarrariKit
import SwiftUI

struct HistorySidebar: View {
    @Bindable var library: HistoryLibrary
    let playback: AudioPlayback
    let fileJob: FileJob
    let isPermissionMissing: Bool
    let isSearchFocused: FocusState<Bool>.Binding
    let onSelect: () -> Void
    let onTranscribeFile: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextInput(
                label: "Search dictations", text: $library.searchText, placeholder: "Search",
                leadingSymbol: "magnifyingglass", focus: isSearchFocused
            )
            .padding(EdgeInsets(top: Space.s2, leading: Space.s14, bottom: Space.s10, trailing: Space.s14))
            .onChange(of: library.searchText) { library.searchChanged() }
            list
            Rectangle().fill(Color.rule).frame(height: ControlMetrics.edge)
            VStack(alignment: .leading, spacing: 0) {
                if let notice = fileJob.notice {
                    FileNoticeView(notice: notice, onDismiss: fileJob.dismissNotice)
                }
                SidebarRow(title: "Transcribe a file", symbol: "waveform.badge.plus", shortcut: "⌘O", action: onTranscribeFile)
                SettingsRowButton(isPermissionMissing: isPermissionMissing, action: onSettings)
            }
            .padding(Space.s8)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if library.hasLoaded, library.results.isEmpty {
                        Text(library.entries.isEmpty ? "No dictations yet" : "No dictations match")
                            .font(Typeface.small)
                            .foregroundStyle(Color.muted)
                            .padding(EdgeInsets(top: Space.s10, leading: Space.s8, bottom: Space.s10, trailing: Space.s8))
                    }
                    ForEach(library.days) { day in
                        Text(day.title)
                            .font(Typeface.label)
                            .foregroundStyle(Color.muted)
                            .padding(EdgeInsets(top: Space.s10, leading: Space.s8, bottom: Space.s4, trailing: Space.s8))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.entries, id: \.id) { entry in
                            HistoryRow(
                                entry: entry, source: EntryFormat.source(entry, apps: library.apps),
                                isSelected: entry.id == library.selection, isPending: entry.id == library.pending?.id
                            ) { select(entry) }
                                .padding(.bottom, WindowMetrics.itemGap)
                                .id(entry.id)
                        }
                    }
                    if library.skippedLines > 0 {
                        Label(skippedText, systemImage: "exclamationmark.circle")
                            .labelStyle(TightLabelStyle())
                            .font(Typeface.meta)
                            .foregroundStyle(Color.muted)
                            .padding(EdgeInsets(top: Space.s10, leading: Space.s8, bottom: Space.s10, trailing: Space.s8))
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
                onSelect()
                if let selection = library.selection { proxy.scrollTo(selection) }
            }
            .onKeyPress(keys: [.space, .return]) { _ in
                guard library.selected.map(library.hasAudio) == true else { return .ignored }
                playback.toggle()
                return .handled
            }
            .onDeleteCommand {
                guard let selected = library.selected, library.canDelete(selected) else { return }
                library.pendingDeletion = selected.id
            }
            .onCopyCommand {
                guard let text = library.selected?.finalText, !text.isEmpty else { return [] }
                return [NSItemProvider(object: text as NSString)]
            }
            .accessibilityLabel("Dictations")
        }
    }

    private var skippedText: String {
        library.skippedLines == 1 ? "1 line in history could not be read" : "\(library.skippedLines) lines in history could not be read"
    }

    private func select(_ entry: HistoryEntry) {
        library.selection = entry.id
        onSelect()
    }
}

// Why the last file was not transcribed, or that one is already running; it stays until dismissed or the next file.
private struct FileNoticeView: View {
    let notice: FileJob.Notice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s2) {
                switch notice {
                case .failed(let fileName, let message):
                    Text(fileName)
                        .font(Typeface.smallStrong)
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    FormError(message: message)
                case .busy:
                    Text(FileJob.busyMessage)
                        .font(Typeface.small)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.icon)
                .accessibilityLabel("Dismiss")
                .iconLabel("Dismiss")
        }
        .padding(EdgeInsets(top: Space.s4, leading: Space.s8, bottom: Space.s8, trailing: 0))
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(spoken).post() }
    }

    private var spoken: String {
        switch notice {
        case .failed(let fileName, let message): "\(fileName): \(message)"
        case .busy: FileJob.busyMessage
        }
    }
}
