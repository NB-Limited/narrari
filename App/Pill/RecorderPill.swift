import AppKit
import NarrariKit
import SwiftUI

@MainActor
final class RecorderPill {
    // One panel for capsule and caption, so both animate in one transaction.
    private static let shadowRoom: CGFloat = 26
    private static let size = NSSize(
        width: max(PillGeometry.captionMaxWidth, PillGeometry.noticeMaxWidth + 2 * MeetingMetrics.foldReach) + 2 * shadowRoom,
        height: PillGeometry.height + PillGeometry.captionGap + Caption.plateHeight(lines: PillGeometry.captionLines)
            + 2 * shadowRoom
    )

    private let surfaces: MeetingSurfaces
    private let motion: ReduceMotion
    private let panel = UnsharedPanel(isKeyable: false)

    init(session: DictationSession, meeting: MeetingSession, surfaces: MeetingSurfaces, looks: PillLookModel, motion: ReduceMotion) {
        self.surfaces = surfaces
        self.motion = motion
        panel.setContentSize(Self.size)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.contentView = NSHostingView(
            rootView: PillHost(
                session: session, meeting: meeting, surfaces: surfaces, looks: looks, bottomInset: Self.shadowRoom,
                onPointer: { [panel] in panel.pointer(isOnSurface: $0) }
            )
                .followsMotion(motion)
        )
        track()
    }

    // Clicks reach the pill only while it carries a meeting; at every other time it lets them through.
    private func track() {
        let (isVisible, takesClicks) = withObservationTracking {
            (surfaces.showsPill, surfaces.pillTakesClicks)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        panel.takeClicks(takesClicks)
        if isVisible, !panel.isShown, let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: screen.midX - Self.size.width / 2,
                y: screen.minY + PillMetrics.screenMargin - Self.shadowRoom
            ))
        }
        panel.present(isVisible, over: isVisible ? PillMotion.appearFade : PillMotion.leave, reducedMotion: motion.isOn)
    }
}

private struct PillHost: View {
    let session: DictationSession
    let meeting: MeetingSession
    let surfaces: MeetingSurfaces
    let looks: PillLookModel
    let bottomInset: CGFloat
    let onPointer: (Bool) -> Void

    @State private var last: PillState?
    @State private var listeningSince: Date?
    @State private var listeningEnded: Date?
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let current = PillState(session)
        ZStack {
            if surfaces.showsDictation, let state = current ?? last {
                TimelineView(.periodic(from: listeningSince ?? .now, by: 1)) { context in
                    PillStage(
                        state: state,
                        meter: PillMeter(seconds: seconds(at: context.date), isListening: session.isListening),
                        look: looks.look,
                        colour: looks.colour,
                        isMeetingFolded: surfaces.isFolded
                    )
                }
                .transition(PillPresence.transition(reduceMotion: reduceMotion))
            } else if let bar = surfaces.pill {
                MeetingCapsule(bar: bar, meeting: meeting, look: looks.look, onClick: surfaces.barClicked)
                    .environment(\.pillLevel, .live { [meeting] in meeting.level })
                    .background(PointerArea(onChange: onPointer))
                    .transition(PillPresence.transition(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(PillPresence.animation(showing: surfaces.showsPill, reduceMotion: reduceMotion), value: surfaces.showsPill)
        .padding(.bottom, bottomInset)
        .environment(\.pillLevel, .live { [session] in session.inputLevel })
        .onChange(of: current, initial: true) { _, current in
            if let current { last = current }
        }
        .onChange(of: current?.capsule.announcement) { _, text in
            guard let text, surfaces.showsDictation else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        .onChange(of: surfaces.pill) { old, new in MeetingAnnouncement.post(from: old, to: new) }
        .onChange(of: current?.silentMicrophone) { _, microphone in
            guard let microphone else { return }
            AccessibilityNotification.Announcement("\(SilencePlate.lead) \(microphone)").post()
        }
        .onChange(of: session.isListening) { _, isListening in
            if isListening {
                listeningSince = .now - session.recordingSeconds
                listeningEnded = nil
            } else {
                listeningEnded = .now
            }
        }
    }

    // The timeline ticks on whole seconds of the recording; the small margin keeps a tick from reading as the second before.
    private func seconds(at date: Date) -> Int {
        guard let listeningSince else { return 0 }
        return max(0, Int((listeningEnded ?? date).timeIntervalSince(listeningSince) + 0.001))
    }
}

// The panel's alpha fades; the view only scales, so the two never double the fade. A surface at the top of the screen
// comes down to rest instead of up. A leave scale of 1 keeps the view still while the panel fades it out.
enum PillPresence {
    static func transition(
        reduceMotion: Bool, anchor: UnitPoint = .bottom, appearScale: Double = PillMotion.appearScale, leaveScale: Double = PillMotion.leaveScale
    ) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: AnyTransition.scale(scale: appearScale, anchor: anchor)
                .combined(with: .offset(y: anchor.y < 0.5 ? -PillMotion.appearRise : PillMotion.appearRise)),
            removal: AnyTransition.scale(scale: leaveScale, anchor: anchor)
        )
    }

    static func animation(
        showing: Bool, reduceMotion: Bool, spring: (duration: Double, bounce: Double) = PillMotion.appearSpring, leave: Double = PillMotion.leave
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        return showing ? .spring(PillStage.spring(spring)) : Motion.Curve.exit.animation(duration: leave)
    }
}
