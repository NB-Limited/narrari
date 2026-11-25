import AppKit
import NarrariKit
import SwiftUI

// Summary, Transcript and Speakers under the head, each tab's buttons at the right of the tabs.
struct MeetingTabs: View {
    @Bindable var page: MeetingPage
    let context: MeetingPageContext
    let isRecording: Bool
    let scroll: ScrollViewProxy
    let followsLive: Bool

    @State private var isConfirmingTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s2) {
                SegmentedControl(
                    label: "Meeting", selection: $page.tab, segments: MeetingPage.Tab.allCases.map { ($0, $0.rawValue) },
                    segmentWidth: MeetingWindowMetrics.tabSegment
                )
                Spacer(minLength: Space.s8)
                actions
            }
            if isConfirmingTranscript, page.tab == .transcript {
                InlineConfirm(
                    message: "Transcribe again? Your edits to the transcript are replaced.", action: "Transcribe again",
                    onCancel: { isConfirmingTranscript = false }, onConfirm: { transcribeAgain() }
                )
                .padding(.top, MeetingWindowMetrics.contentTop)
            }
            Group {
                switch page.tab {
                case .summary: SummaryTab(page: page, isRecording: isRecording, store: context.library.store)
                case .transcript: TranscriptTab(page: page, context: context, isRecording: isRecording, scroll: scroll, followsLive: followsLive)
                case .speakers: SpeakersTab(page: page, playback: context.playback, isRecording: isRecording)
                }
            }
            .padding(.top, MeetingWindowMetrics.contentTop)
        }
    }

    @ViewBuilder private var actions: some View {
        switch page.tab {
        case .summary:
            AgainButton(page: page, step: .summary, unavailable: unavailable(.summary), action: openRedo)
            CopyButton(text: page.summary, look: .icon(label: "Copy summary", shortcut: "⌘C"))
                .disabled(page.summary.isEmpty)
                .meetsEdge()
        case .transcript:
            if let count = page.matchCount {
                Text(count).font(Typeface.small).foregroundStyle(Color.ink2).monospacedDigit()
                    .padding(.trailing, Space.s2)
                Button { page.showMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.icon)
                    .accessibilityLabel("Previous match")
                    .iconLabel("Previous match")
                Button { page.showMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.icon)
                    .accessibilityLabel("Next match")
                    .iconLabel("Next match")
                    .padding(.trailing, Space.s4)
            }
            AgainButton(page: page, step: .transcript, unavailable: unavailable(.transcript)) { _ in
                if page.meeting.linesEdited { isConfirmingTranscript = true } else { transcribeAgain() }
            }
            CopyButton(text: page.transcriptText, look: .icon(label: "Copy transcript", shortcut: "⌘C"))
                .disabled(page.segments.isEmpty)
                .meetsEdge()
        case .speakers:
            AgainButton(page: page, step: .speakers, unavailable: unavailable(.speakers), action: openSpeakerCount)
                .meetsEdge()
        }
    }

    private func unavailable(_ step: MeetingProcessing.Step) -> String? {
        if isRecording { return "Comes after the meeting" }
        if step != .summary, !page.hasAudio { return "No audio kept" }
        if page.isProcessing { return "Wait until the steps are done" }
        switch step {
        case .summary: return page.canRedoSummary ? nil : "No summary yet"
        case .speakers: return page.meeting.steps.transcript.status == .done ? nil : "Comes after the transcript"
        case .transcript, .echo: return nil
        }
    }

    private func transcribeAgain() {
        isConfirmingTranscript = false
        Task { await page.redo(.transcript) }
    }

    private func openSpeakerCount(from view: NSView?) {
        guard let view else { return }
        let others = Array(0...8)
        let ownSide = page.hasCallTrack ? Array(0...4) : []
        let rows = countRows(others, group: page.speakerCountTitle, checked: page.meeting.speakerCount)
            + countRows(ownSide, group: "People on your side", checked: page.meeting.ownSideCount)
        Dropdown.shared.open(label: "Find speakers again", rows: rows, chosen: nil, from: view, alignment: .trailing) { index in
            Task {
                if index < others.count {
                    await page.findSpeakersAgain(count: others[index])
                } else {
                    await page.findSpeakersAgain(ownSide: ownSide[index - others.count])
                }
            }
        }
    }

    private func countRows(_ counts: [Int], group: String, checked: Int) -> [DropdownRow] {
        counts.map { count in
            DropdownRow(title: count == 0 ? "Detect" : "\(count)", group: count == 0 ? group : nil, isChecked: count == checked)
        }
    }

    // The templates, then the models; choosing either writes the summary again with the other as it is checked.
    private func openRedo(from view: NSView?) {
        guard let view else { return }
        let templates = context.templates()
        let models = context.summaryModels.choices()
        let template = page.meeting.template
        let model = context.summaryModels.resolved(page.meeting.summaryModel)
        let rows = templates.map { DropdownRow(title: $0.title, isChecked: $0.id == template) }
            + models.enumerated().map { index, choice in
                DropdownRow(
                    title: choice.name, detail: choice.id == SummaryModels.outside ? "Text leaves this Mac" : nil,
                    group: index == 0 ? "Model" : nil, startsSection: index == 0, isChecked: choice.id == model
                )
            }
        Dropdown.shared.open(label: "Redo summary", rows: rows, chosen: nil, from: view, alignment: .trailing) { index in
            let isTemplate = templates.indices.contains(index)
            let chosenTemplate = isTemplate ? templates[index].id : template
            let chosenModel = isTemplate ? model : models[index - templates.count].id
            Task { await page.redoSummary(with: chosenTemplate, model: chosenModel) }
        }
    }
}

private struct SummaryTab: View {
    let page: MeetingPage
    let isRecording: Bool
    let store: MeetingStore

    @State private var isDetailsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page.summary.isEmpty {
                page.emptyLine(for: .summary).map(EmptyTabLine.init)
            } else {
                SummaryText(text: page.summary)
            }
            Text("Notes")
                .font(Typeface.label)
                .tracking(Typeface.groupTracking)
                .foregroundStyle(Color.muted)
                .frame(height: MeetingWindowMetrics.notesHead, alignment: .bottom)
                .padding(.top, MeetingWindowMetrics.notesTop)
                .padding(.bottom, Space.s4)
                .accessibilityAddTraits(.isHeader)
            NotesField(page: page, isFocusedFirst: isRecording)
            if !isRecording {
                DisclosureButton(title: "Details", isOpen: $isDetailsOpen)
                    .meetsEdge(.leading)
                    .padding(.top, Space.s16)
                if isDetailsOpen {
                    details.transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder private var details: some View {
        let meeting = page.meeting
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: Space.s4) {
            detail("Recorded", page.audio.count > 1 || meeting.systemSound == .unheard ? "Your microphone and the call's sound" : "Your microphone")
            if !page.stepsLine.isEmpty { detail("Steps", page.stepsLine) }
            if let madeWith = page.madeWith { detail("Made with", madeWith) }
            detail("Audio", page.hasAudio ? (meeting.pinned ? "Kept, because the meeting is pinned" : "Kept") : "Removed")
        }
        .font(Typeface.small)
        .padding(.top, Space.s4)
        Button("Show in Finder") {
            Task {
                guard let folder = try? await store.folder(of: meeting.id) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        .buttonStyle(.secondary)
        .padding(.top, Space.s12)
    }

    private func detail(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(Color.muted).frame(width: MeetingWindowMetrics.detailKey, alignment: .leading)
            Text(value).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// The template's headings as small heads, its lists indented, the rest in the serif.
private struct SummaryText: View {
    let text: String

    var body: some View {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                if line.hasPrefix("#") {
                    Text(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                        .font(Typeface.smallStrong)
                        .foregroundStyle(Color.ink2)
                        .padding(.top, index == 0 ? Space.s2 : MeetingWindowMetrics.headingTop)
                        .padding(.bottom, Space.s2)
                        .accessibilityAddTraits(.isHeader)
                } else if let item = Self.item(line) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("•").frame(width: MeetingWindowMetrics.listIndent, alignment: .leading)
                        Text(item)
                    }
                    .serif()
                } else {
                    Text(line).serif()
                }
            }
        }
        .textSelection(.enabled)
    }

    private static func item(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        return String(trimmed.dropFirst(2))
    }
}

private extension View {
    func serif() -> some View {
        font(Typeface.heard)
            .lineSpacing(Typeface.heardLineSpacing)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// A Window plate in the serif, saved as typed, during and after the meeting.
private struct NotesField: View {
    let page: MeetingPage
    let isFocusedFirst: Bool

    @FocusState private var isFocused: Bool

    // TextEditor's text view starts each line this far in; the placeholder starts there too, so the caret stands before it,
    // and the plate pads that much less, so both start 12 in.
    private static let textStart = NSTextContainer().lineFragmentPadding
    private static let platePadding = EdgeInsets(
        top: MeetingWindowMetrics.notesPadding.top, leading: MeetingWindowMetrics.notesPadding.leading - textStart,
        bottom: MeetingWindowMetrics.notesPadding.bottom, trailing: MeetingWindowMetrics.notesPadding.trailing - textStart
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            plate
            if let problem = page.notesProblem {
                FormError(message: problem.message).padding(.top, ControlMetrics.errorGap)
            }
        }
    }

    private var plate: some View {
        ZStack(alignment: .topLeading) {
            if page.notes.isEmpty {
                Text("Type notes. The summary uses them.")
                    .font(Typeface.heard)
                    .foregroundStyle(Color.muted)
                    .padding(.leading, Self.textStart)
                    .accessibilityHidden(true)
            }
            TextEditor(text: Binding(get: { page.notes }, set: { page.setNotes($0) }))
                .font(Typeface.heard)
                .lineSpacing(Typeface.heardLineSpacing)
                .foregroundStyle(Color.ink)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .tint(Color.ink)
                .focused($isFocused)
                .accessibilityLabel("Notes")
        }
        .frame(minHeight: MeetingWindowMetrics.notesMinHeight, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Self.platePadding)
        .background(Color.windowGround, in: RoundedRectangle(cornerRadius: Radius.control))
        .focusRing(isFocused)
        .onAppear { if isFocusedFirst { isFocused = true } }
    }
}

private struct SpeakersTab: View {
    let page: MeetingPage
    let playback: AudioPlayback
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line = page.emptyLine(for: .speakers) {
                EmptyTabLine(text: line)
                    .padding(.bottom, page.speakerRows.isEmpty ? 0 : Space.s8)
            }
            if !isRecording, !page.speakerRows.isEmpty {
                ForEach(page.speakerRows) { row in
                    HStack(alignment: .nameLine, spacing: Space.s8) {
                        VStack(alignment: .leading, spacing: MeetingWindowMetrics.speakerDetailTop) {
                            HStack(spacing: Space.s4 + Space.s2) {
                                if row.speaker.id == MeetingTranscript.ownerID {
                                    Text(MeetingPage.name(of: row.speaker)).font(Typeface.bodyStrong).foregroundStyle(Color.ink)
                                } else {
                                    SpeakerChip(speaker: row.speaker, page: page, isLarge: true)
                                }
                                if row.speaker.isGuess == true { Tag(text: "Guess") }
                            }
                            .alignmentGuide(.nameLine) { $0[VerticalAlignment.center] }
                            Text(row.detail).font(Typeface.small).foregroundStyle(Color.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SpeakerPlayButton(speaker: row.speaker, page: page, playback: playback)
                            .meetsEdge()
                    }
                    .padding(.vertical, SettingsGrid.rowPadding)
                    .frame(minHeight: SettingsGrid.rowMinHeight, alignment: .leading)
                }
                Text(page.usesVoiceMemory ? "Names you choose are remembered for the next meeting." : "Voice memory is off. Speakers stay numbered.")
                    .font(Typeface.small)
                    .foregroundStyle(Color.muted)
                    .padding(.top, MeetingWindowMetrics.quietTop)
            }
        }
    }
}

// The play button sits on the name line, whether the name is a chip or plain text.
private extension VerticalAlignment {
    private enum NameLine: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
    }

    static let nameLine = VerticalAlignment(NameLine.self)
}

// Plays only this speaker's lines on the page's one player, so the audio bar follows; any other control leaves it.
private struct SpeakerPlayButton: View {
    let speaker: Meeting.Speaker
    let page: MeetingPage
    let playback: AudioPlayback

    var body: some View {
        let part = page.part(of: speaker.id)
        let isPlaying = playback.isPlaying && playback.part?.id == speaker.id
        let whom = speaker.id == MeetingTranscript.ownerID ? "your lines" : speaker.name
        let label = isPlaying ? "Pause \(whom)" : "Play \(whom)"
        let unavailable = page.hasAudio ? nil : "No audio kept"
        if !part.stretches.isEmpty {
            Button { playback.toggle(part) } label: { Image(systemName: isPlaying ? "pause.circle" : "play.circle") }
                .buttonStyle(.icon)
                .disabled(unavailable != nil)
                .accessibilityLabel(label)
                .accessibilityHint(unavailable ?? "")
                .iconLabel(unavailable ?? label)
        }
    }
}
