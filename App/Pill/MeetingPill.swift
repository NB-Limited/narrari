import NarrariKit
import SwiftUI

// What the meeting bar reads and does; the Settings preview draws it from a still meeting.
protocol MeetingControls {
    var recordedSeconds: Double { get }
    func pause()
    func resume()
    func keepRecording()
    func stop() async
}

extension MeetingSession: MeetingControls {}

// The meeting in the recorder capsule, when the meeting bar is the pill.
struct MeetingCapsule: View {
    let bar: MeetingSurfaces.Bar
    let meeting: any MeetingControls
    let look: PillLook
    let onClick: () -> Void

    @Namespace private var glass
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        PillGlassGroup {
            MeetingBarContent(bar: bar, meeting: meeting)
                .clipShape(Capsule())
                .contentShape(Capsule())
                .onTapGesture(perform: onClick)
                .modifier(PillSurface(radius: PillGeometry.height / 2, depth: .capsule, id: "meeting", glass: glass))
        }
        .environment(\.colorScheme, .dark)
        .environment(\.pillLook, look)
        .animation(reduceMotion ? nil : .spring(PillStage.spring(PillMotion.widthSpring)), value: bar)
    }
}

// What the meeting bar carries: the pill's whole content, and what the corner chip opens into.
struct MeetingBarContent: View {
    let bar: MeetingSurfaces.Bar
    let meeting: any MeetingControls

    var body: some View {
        HStack(spacing: 0) {
            switch bar {
            case .recording:
                RecordDot()
                LevelBars(isListening: true).padding(.leading, PillGeometry.recordingGap)
                MeetingTimer(meeting: meeting).padding(.leading, PillGeometry.recordingGap)
                controls(isPaused: false)
            case .paused:
                PillSymbol(name: "pause.fill")
                Text("Paused").onPillBaseline().padding(.leading, PillGeometry.recordingGap)
                MeetingTimer(meeting: meeting).padding(.leading, PillGeometry.recordingGap)
                controls(isPaused: true)
            case .callEnded(let left):
                RecordDot()
                Text(MeetingSurfaces.countdownText(secondsLeft: left)).onPillBaseline().padding(.leading, PillGeometry.recordingGap)
                PillTextButton(title: "Keep recording") { meeting.keepRecording() }
                    .padding(.leading, PillGeometry.recordingGap)
            case .trouble(let trouble):
                let label = PillLabel(trouble)
                PillSymbol(name: label.symbol, isError: true)
                Text(label.text)
                    .lineLimit(1)
                    .frame(maxWidth: PillWidths.noticeTextMax, alignment: .leading)
                    .onPillBaseline()
                    .padding(.leading, PillGeometry.symbolGap)
                controls(isPaused: false)
            case .notice(let notice):
                let label = PillLabel(notice)
                PillSymbol(name: label.symbol, isError: label.isError)
                Text(label.text)
                    .lineLimit(1)
                    .frame(maxWidth: PillWidths.noticeTextMax, alignment: .leading)
                    .onPillBaseline()
                    .padding(.leading, PillGeometry.symbolGap)
                    .padding(.trailing, PillGeometry.padding - MeetingMetrics.trailing)
            }
        }
        .fixedSize()
        .font(Typeface.pill)
        .foregroundStyle(Color.pillText)
        .padding(.leading, MeetingMetrics.leading)
        .padding(.trailing, MeetingMetrics.trailing)
        .frame(height: PillGeometry.height)
    }

    @ViewBuilder
    private func controls(isPaused: Bool) -> some View {
        Rectangle()
            .fill(Color.pillText.opacity(MeetingMetrics.dividerOpacity))
            .frame(width: ControlMetrics.edge, height: MeetingMetrics.dividerHeight)
            .padding(.leading, MeetingMetrics.dividerBefore)
            .padding(.trailing, MeetingMetrics.dividerAfter)
            .accessibilityHidden(true)
        if isPaused {
            PillIconButton(symbol: "play.fill", label: "Resume recording") { meeting.resume() }
        } else {
            PillIconButton(symbol: "pause.fill", label: "Pause recording") { meeting.pause() }
        }
        PillIconButton(symbol: "stop.fill", label: "Stop recording") { Task { await meeting.stop() } }
    }
}

// The meeting folded beside a dictation's capsule: a circle with the mark, not a control.
struct FoldedMeeting: View {
    let glass: Namespace.ID

    var body: some View {
        RecordDot()
            .frame(width: PillGeometry.doneDiameter, height: PillGeometry.doneDiameter)
            .modifier(PillSurface(radius: PillGeometry.doneDiameter / 2, depth: .capsule, id: "folded-meeting", glass: glass))
            .accessibilityHidden(true)
    }
}

// Held still: a pulse would pull the eye for the length of a meeting.
struct RecordDot: View {
    var body: some View {
        Circle()
            .fill(Color.pillRecord)
            .frame(width: MeetingMetrics.dot, height: MeetingMetrics.dot)
            .frame(width: PillGeometry.symbol, height: PillGeometry.symbol)
            .accessibilityHidden(true)
    }
}

// Time recorded, paused time left out, read from the recorder on each tick.
struct MeetingTimer: View {
    let meeting: any MeetingControls
    var ink = Color.pillMuted

    var body: some View {
        TimelineView(.periodic(from: .now, by: MeetingMetrics.timerTick)) { _ in
            Text(MeetingSurfaces.elapsedText(seconds: meeting.recordedSeconds))
                .font(Typeface.pillTimer)
                .foregroundStyle(ink)
                .onPillBaseline()
        }
    }
}

enum MeetingAnnouncement {
    // The countdown is announced when it starts, not on every second.
    static func post(from old: MeetingSurfaces.Bar?, to new: MeetingSurfaces.Bar?) {
        guard let new else { return }
        if case .callEnded = old, case .callEnded = new { return }
        AccessibilityNotification.Announcement(new.announcement).post()
    }
}
