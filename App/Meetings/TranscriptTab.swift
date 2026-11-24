import NarrariKit
import SwiftUI

// Turns by speaker. A click on a line plays from it and a double-click edits it; Up and Down move between lines, Space plays,
// Return edits.
struct TranscriptTab: View {
    let page: MeetingPage
    let context: MeetingPageContext
    let isRecording: Bool
    let scroll: ScrollViewProxy
    // False once the user scrolls up from the end, until they scroll back to it.
    let followsLive: Bool

    @State private var editing: Int?
    @State private var playing: Set<Int> = []
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingWindowMetrics.turnGap) {
            if isRecording || page.segments.isEmpty && hasLiveLines {
                live
            } else if page.segments.isEmpty {
                page.emptyLine(for: .transcript).map(EmptyTabLine.init)
            } else {
                ForEach(page.turns) { turn in
                    VStack(alignment: .leading, spacing: MeetingWindowMetrics.lineTop) {
                        speakerLine(turn.speaker, start: turn.lines.first?.segment.start ?? 0)
                        lines(turn)
                    }
                }
            }
        }
        .padding(.top, Space.s4)
        .background(PlayingLines(page: page, playback: context.playback, playing: $playing))
        .onMoveCommand { direction in
            let count = page.segments.count
            guard editing == nil, count > 0 else { return }
            switch direction {
            case .up: focused = max((focused ?? 1) - 1, 0)
            case .down: focused = min((focused ?? -1) + 1, count - 1)
            default: return
            }
        }
        .task(id: page.matchLine) {
            guard let line = page.matchLine else { return }
            scroll.scrollTo(line, anchor: .center)
        }
    }

    @ViewBuilder private var live: some View {
        let turns = context.session.liveText.map { MeetingPage.liveTurns($0.lines, waiting: $0.pending) } ?? []
        ForEach(turns) { turn in
            VStack(alignment: .leading, spacing: MeetingWindowMetrics.lineTop) {
                HStack(spacing: MeetingWindowMetrics.speakerLineGap) {
                    Text(turn.speaker).font(Typeface.smallStrong).foregroundStyle(Color.ink2)
                    Text(MeetingSurfaces.elapsedText(seconds: turn.start)).font(Typeface.small).foregroundStyle(Color.muted).monospacedDigit()
                }
                (Text(turn.text) + Text(turn.waiting.isEmpty ? "" : (turn.text.isEmpty ? "" : " ") + turn.waiting).foregroundColor(.muted))
                    .font(Typeface.heard)
                    .lineSpacing(Typeface.heardLineSpacing)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(turn.id)
        }
        .onChange(of: turns.last?.id) { _, last in
            if let last, followsLive { scroll.scrollTo(last, anchor: .bottom) }
        }
    }

    // The lines stay after the meeting stops, until the transcript replaces them.
    private var hasLiveLines: Bool {
        context.session.liveTextMeetingID == page.meeting.id && context.session.liveText?.lines.isEmpty == false
    }

    private func speakerLine(_ speaker: Meeting.Speaker, start: Double) -> some View {
        HStack(spacing: MeetingWindowMetrics.speakerLineGap) {
            HStack(spacing: Space.s4) {
                if speaker.id == MeetingTranscript.ownerID {
                    Text(MeetingPage.name(of: speaker)).font(Typeface.smallStrong).foregroundStyle(Color.ink2)
                } else {
                    SpeakerChip(speaker: speaker, page: page, isLarge: false)
                }
                if speaker.isGuess == true { Tag(text: "Guess") }
            }
            Text(MeetingSurfaces.elapsedText(seconds: start)).font(Typeface.small).foregroundStyle(Color.muted).monospacedDigit()
        }
    }

    // Each line stands on its own, so it is its own target to play from and edit.
    private func lines(_ turn: MeetingPage.Turn) -> some View {
        ForEach(turn.lines.map(\.index), id: \.self) { index in
            let segment = page.segments[index]
            if editing == index {
                LineEditor(text: segment.text) { text in
                    editing = nil
                    focused = index
                    if let text { Task { await page.edit(line: index, to: text) } }
                }
            } else {
                TranscriptLine(
                    segment: segment, query: page.searchText, hasAudio: page.hasAudio,
                    isPlaying: playing.contains(index), speaker: MeetingPage.name(of: turn.speaker)
                ) {
                    focused = index
                    context.playback.play(from: segment.start)
                } onEdit: {
                    editing = index
                }
                .focused($focused, equals: index)
                .id(index)
            }
        }
    }
}

// The only view that reads the playback position, 20 times a second; the lines hear of it only when the playing line changes.
private struct PlayingLines: View {
    let page: MeetingPage
    let playback: AudioPlayback
    @Binding var playing: Set<Int>

    var body: some View {
        let now = page.playingLines(at: playback.position, isPlaying: playback.isPlaying)
        Color.clear.onChange(of: now, initial: true) { _, new in playing = new }
    }
}

// One line of a turn; its words keep reading on from the line before.
// Equal when what it shows is equal, so a change of playing line redraws two lines, not every line; the actions follow the line.
private struct TranscriptLine: View, Equatable {
    let segment: TranscriptSegment
    let query: String
    let hasAudio: Bool
    let isPlaying: Bool
    let speaker: String
    let onPlay: () -> Void
    let onEdit: () -> Void

    @State private var isHovered = false
    @Environment(\.isFocused) private var isFocused

    static func == (left: Self, right: Self) -> Bool {
        left.segment == right.segment && left.query == right.query && left.hasAudio == right.hasAudio
            && left.isPlaying == right.isPlaying && left.speaker == right.speaker
    }

    var body: some View {
        Text(Marked.text(segment.text, query: query))
            .font(Typeface.heard)
            .lineSpacing(Typeface.heardLineSpacing)
            .foregroundStyle(Color.ink)
            .underline(isPlaying, color: .ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MeetingWindowMetrics.lineHover)
            .background(isHovered && hasAudio ? Color.selectionFill : .clear, in: RoundedRectangle(cornerRadius: MeetingWindowMetrics.lineHover))
            .padding(.horizontal, -MeetingWindowMetrics.lineHover)
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded(onEdit).exclusively(before: TapGesture().onEnded { if hasAudio { onPlay() } }))
            .onHover { isHovered = $0 }
            .focusable()
            .focusEffectDisabled()
            .focusRing(isFocused, radius: MeetingWindowMetrics.lineHover)
            .onKeyPress(.space) {
                guard hasAudio else { return .ignored }
                onPlay()
                return .handled
            }
            .onKeyPress(.return) {
                onEdit()
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("\(speaker), \(MeetingSurfaces.elapsedText(seconds: segment.start))")
            .accessibilityValue(segment.text)
            .accessibilityAction(named: "Play from here") { if hasAudio { onPlay() } }
            .accessibilityAction(named: "Edit") { onEdit() }
    }
}

// The line's text in place, in the same type; Return keeps it, Escape leaves it as it was.
private struct LineEditor: View {
    @State var text: String
    let onDone: (String?) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Line", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Typeface.heard)
            .lineSpacing(Typeface.heardLineSpacing)
            .foregroundStyle(Color.ink)
            .tint(Color.ink)
            .focused($isFocused)
            .focusRing(true, radius: MeetingWindowMetrics.lineHover)
            .onAppear { isFocused = true }
            .onSubmit { onDone(text) }
            .onExitCommand { onDone(nil) }
            .takesEscape()
            .accessibilityLabel("Line")
    }
}

// A speaker's name that opens the speaker menu: rename, merge, or "Not this person".
struct SpeakerChip: View {
    let speaker: Meeting.Speaker
    let page: MeetingPage
    let isLarge: Bool

    @State private var anchor = Anchor()
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            Text(speaker.name)
                .font(isLarge ? Typeface.bodyStrong : Typeface.smallStrong)
                .foregroundStyle(isLarge || isHovered ? Color.ink : Color.ink2)
                .padding(.horizontal, MeetingWindowMetrics.chipPadding)
                .frame(height: MeetingWindowMetrics.chipHeight)
                .background(isHovered ? Color.selectionFill : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .padding(.leading, -MeetingWindowMetrics.chipPadding)
        .onHover { isHovered = $0 }
        .background(AnchorView(anchor: anchor))
        .accessibilityLabel(speaker.isGuess == true ? "\(speaker.name), Guess" : speaker.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the speaker menu")
    }

    private func open() {
        guard let view = anchor.view else { return }
        let field = DropdownField(placeholder: "Type a name") { [page, speaker] typed in
            page.menu(for: speaker, query: typed).map { row in
                DropdownRow(
                    title: row.title, detail: row.detail, group: row.group, startsSection: row.startsSection, isChecked: row.isChecked,
                    action: { Task { await page.choose(row.action, for: speaker.id) } }
                )
            }
        }
        Dropdown.shared.open(label: "Speaker \(speaker.name)", field: field, from: view)
    }
}
