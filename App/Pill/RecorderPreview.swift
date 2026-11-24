import AppKit
import NarrariKit
import SwiftUI

// The real recorder at true size over a light and a dark page. It plays only while its window is on screen; with Reduce Motion it holds one frame.
// Given a meeting bar, it holds that bar still, recording.
struct RecorderPreview: View {
    let look: PillLook
    let colour: PillColour
    let showsWords: Bool
    var meetingBar: MeetingBar?

    @State private var frame = PillDemo.still(showsWords: true)
    @State private var started = ContinuousClock.now
    @State private var isVisible = false
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PillPreviewMetrics.gap) {
            stage(page: PillPreviewMetrics.lightPage, line: PillPreviewMetrics.lightLine)
            stage(page: PillPreviewMetrics.darkPage, line: PillPreviewMetrics.darkLine)
        }
        .environment(\.pillWithinWindow, true)
        .environment(\.pillLevel, level)
        .background(WindowVisibility(isVisible: $isVisible))
        .task(id: [isVisible, reduceMotion, showsWords]) { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
    }

    private var accessibilityName: String {
        switch meetingBar {
        case .pill: "Preview of the meeting in the recorder pill"
        case .chip: "Preview of the meeting in the corner chip"
        case nil: "Preview of the \(look.name) recorder"
        }
    }

    private func stage(page: Color, line: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: PillPreviewMetrics.radius, style: .continuous)
        return ZStack(alignment: .bottom) {
            PreviewPage(page: page, line: line)
            if let meetingBar {
                StillMeetingBar(bar: meetingBar, look: look)
            } else if let state = frame.state {
                PillStage(state: state, meter: PillMeter(seconds: frame.seconds, isListening: frame.isListening), look: look, colour: colour)
                    .padding(.bottom, PillPreviewMetrics.bottom)
                    .transition(PillPresence.transition(reduceMotion: reduceMotion))
            }
        }
        .animation(PillPresence.animation(showing: frame.state != nil, reduceMotion: reduceMotion), value: frame.state == nil)
        .frame(maxWidth: .infinity)
        .frame(height: PillPreviewMetrics.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.rule, lineWidth: ControlMetrics.edge) }
    }

    private var isPlaying: Bool {
        isVisible && !reduceMotion && meetingBar == nil
    }

    private var level: PillLevel {
        guard isPlaying else { return .held(Self.stillBars) }
        return .live { [started, showsWords] in
            PillDemo.frame(at: Self.seconds(since: started), showsWords: showsWords).level
        }
    }

    private func play() async {
        guard isPlaying else {
            frame = PillDemo.still(showsWords: showsWords)
            return
        }
        started = .now
        repeat {
            let next = PillDemo.frame(at: Self.seconds(since: started), showsWords: showsWords)
            if next.state != frame.state || next.isListening != frame.isListening || next.seconds != frame.seconds {
                frame = next
            }
        } while (try? await Task.sleep(for: PillDemo.step)) != nil
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private static let stillBars: [LevelMeter.Bar] = {
        var level = LevelMeter()
        level.follow(PillDemo.still(showsWords: false).level, over: 1)
        return level.bars(at: 1.3, breathing: false)
    }()
}

// The meeting bar as it sits on screen: the pill at the bottom centre, the chip in the top right corner.
private struct StillMeetingBar: View {
    let bar: MeetingBar
    let look: PillLook

    var body: some View {
        Group {
            switch bar {
            case .pill:
                MeetingCapsule(bar: .recording, meeting: StillMeeting(), look: look, onClick: {})
                    .padding(.bottom, PillPreviewMetrics.bottom)
            case .chip:
                MeetingChipView(bar: .recording, isOpen: false, meeting: StillMeeting(), look: look, onClick: {})
                    .padding(.top, MeetingMetrics.cornerBelowMenuBar)
                    .padding(.trailing, MeetingMetrics.cornerFromEdge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .allowsHitTesting(false)
    }
}

// Twelve minutes into a meeting; the preview's buttons do nothing.
private struct StillMeeting: MeetingControls {
    let recordedSeconds: Double = 724

    func pause() {}
    func resume() {}
    func keepRecording() {}
    func stop() async {}
}

private struct PreviewPage: View {
    let page: Color
    let line: Color

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: PillPreviewMetrics.lineGap) {
                ForEach(PillPreviewMetrics.lines.indices, id: \.self) { index in
                    Capsule()
                        .fill(line)
                        .frame(
                            width: (proxy.size.width - 2 * PillPreviewMetrics.linePadding) * PillPreviewMetrics.lines[index],
                            height: PillPreviewMetrics.lineHeight
                        )
                }
            }
            .padding(PillPreviewMetrics.linePadding)
        }
        .background(page)
    }
}

// Occlusion, not appearance: a closed Settings window keeps its views, so only this tells the loop to stop.
private struct WindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = { isVisible = $0 }
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            let isVisible = window?.occlusionState.contains(.visible) ?? false
            Task { @MainActor [weak self] in self?.onChange?(isVisible) }
        }
    }
}
