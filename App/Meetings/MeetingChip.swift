import AppKit
import NarrariKit
import SwiftUI

// The meeting bar as a chip at the top right: the mark and the time, opening into the bar's controls.
@MainActor
final class MeetingChip {
    static let shadowRoom: CGFloat = 26

    private let surfaces: MeetingSurfaces
    private let motion: ReduceMotion
    private let panel = UnsharedPanel(isKeyable: false)

    init(meeting: MeetingSession, surfaces: MeetingSurfaces, looks: PillLookModel, motion: ReduceMotion) {
        self.surfaces = surfaces
        self.motion = motion
        panel.setContentSize(NSSize(
            width: PillGeometry.noticeMaxWidth + 2 * Self.shadowRoom, height: PillGeometry.height + 2 * Self.shadowRoom
        ))
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: ChipHost(meeting: meeting, surfaces: surfaces, looks: looks).followsMotion(motion))
        track()
    }

    private func track() {
        let bar = withObservationTracking {
            surfaces.chip
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        panel.ignoresMouseEvents = bar?.takesClicks != true
        if bar != nil, !panel.isShown { panel.placeInCorner(shadowRoom: Self.shadowRoom) }
        panel.present(bar != nil, over: bar != nil ? PillMotion.appearFade : PillMotion.leave, reducedMotion: motion.isOn)
    }
}

extension UnsharedPanel {
    // The content's top right corner 8 below the menu bar and 12 from the edge of the screen that has the menu bar.
    func placeInCorner(shadowRoom: CGFloat) {
        guard let screen = NSScreen.screens.first else { return }
        setFrameOrigin(NSPoint(
            x: screen.frame.maxX - MeetingMetrics.cornerFromEdge + shadowRoom - frame.width,
            y: screen.visibleFrame.maxY - MeetingMetrics.cornerBelowMenuBar + shadowRoom - frame.height
        ))
    }
}

private struct ChipHost: View {
    let meeting: MeetingSession
    let surfaces: MeetingSurfaces
    let looks: PillLookModel

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let bar = surfaces.chip {
                MeetingChipView(bar: bar, isOpen: surfaces.isChipOpen, meeting: meeting, look: looks.look, onClick: surfaces.barClicked)
                    .environment(\.pillLevel, .live { [meeting] in meeting.level })
                    .background(PointerArea { surfaces.pointer(isInside: $0) })
                    .transition(PillPresence.transition(reduceMotion: reduceMotion, anchor: .topTrailing))
            }
        }
        .animation(PillPresence.animation(showing: surfaces.chip != nil, reduceMotion: reduceMotion), value: surfaces.chip != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(MeetingChip.shadowRoom)
        .onChange(of: surfaces.chip) { old, new in MeetingAnnouncement.post(from: old, to: new) }
    }
}

struct MeetingChipView: View {
    let bar: MeetingSurfaces.Bar
    let isOpen: Bool
    let meeting: any MeetingControls
    let look: PillLook
    let onClick: () -> Void

    @Namespace private var glass
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        PillGlassGroup {
            Group {
                if isOpen {
                    MeetingBarContent(bar: bar, meeting: meeting)
                } else {
                    closed
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture(perform: onClick)
            .modifier(PillSurface(radius: PillGeometry.height / 2, depth: .capsule, id: "chip", glass: glass))
        }
        .environment(\.colorScheme, .dark)
        .environment(\.pillLook, look)
        .animation(reduceMotion ? nil : .spring(PillStage.spring(PillMotion.widthSpring)), value: isOpen)
        .animation(reduceMotion ? nil : .spring(PillStage.spring(PillMotion.widthSpring)), value: bar)
    }

    private var closed: some View {
        let isPaused = bar == .paused
        return HStack(spacing: MeetingMetrics.chipGap) {
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: MeetingMetrics.chipSymbol))
                    .frame(width: PillGeometry.symbol)
            } else {
                RecordDot()
            }
            MeetingTimer(meeting: meeting, ink: isPaused ? .pillMuted : .pillText)
        }
        .fixedSize()
        .foregroundStyle(Color.pillText)
        .padding(.horizontal, PillGeometry.padding)
        .frame(height: PillGeometry.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Paused" : "Recording meeting")
    }
}
