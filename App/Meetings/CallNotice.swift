import AppKit
import NarrariKit
import SwiftUI

// The offer to record a call, top right. Never key, so the call app keeps the keyboard.
@MainActor
final class CallNotice {
    private static let shadowRoom: CGFloat = 26
    // Room for the head row and two lines of the event's title.
    private static let height: CGFloat = 96

    private let surfaces: MeetingSurfaces
    private let motion: ReduceMotion
    private let panel = UnsharedPanel(isKeyable: false)

    init(
        meeting: MeetingSession, surfaces: MeetingSurfaces, looks: PillLookModel, motion: ReduceMotion,
        app: @escaping @MainActor (String) -> AppDirectory.App
    ) {
        self.surfaces = surfaces
        self.motion = motion
        panel.setContentSize(NSSize(width: MeetingMetrics.noticeWidth + 2 * Self.shadowRoom, height: Self.height + 2 * Self.shadowRoom))
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.alphaValue = 0
        let host = NoticeHost(meeting: meeting, surfaces: surfaces, looks: looks, app: app, inset: Self.shadowRoom)
        panel.contentView = NSHostingView(rootView: host.followsMotion(motion))
        track()
    }

    private func track() {
        let isOffered = withObservationTracking {
            surfaces.offer != nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        if isOffered, !panel.isShown { panel.placeInCorner(shadowRoom: Self.shadowRoom) }
        panel.present(isOffered, over: isOffered ? MeetingMetrics.noticeEnter : MeetingMetrics.noticeLeave, reducedMotion: motion.isOn)
    }
}

private struct NoticeHost: View {
    let meeting: MeetingSession
    let surfaces: MeetingSurfaces
    let looks: PillLookModel
    let app: @MainActor (String) -> AppDirectory.App
    let inset: CGFloat

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let offer = surfaces.offer {
                let called = app(offer.app)
                CallNoticeView(appName: called.name, icon: called.icon, title: offer.title, meeting: meeting, look: looks.look)
                    .onAppear { AccessibilityNotification.Announcement("\(called.name) call. Start recording?").post() }
                    .transition(PillPresence.transition(
                        reduceMotion: reduceMotion, anchor: .topTrailing, appearScale: MeetingMetrics.noticeScale, leaveScale: 1
                    ))
            }
        }
        .animation(
            PillPresence.animation(
                showing: surfaces.offer != nil, reduceMotion: reduceMotion, spring: MeetingMetrics.noticeSpring, leave: MeetingMetrics.noticeLeave
            ),
            value: surfaces.offer != nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(inset)
    }
}

struct CallNoticeView: View {
    let appName: String
    let icon: NSImage?
    let title: String?
    let meeting: MeetingSession
    let look: PillLook

    @Namespace private var glass

    var body: some View {
        let event = title.flatMap { $0.isEmpty ? nil : $0 }
        let padding = MeetingMetrics.noticePadding
        PillGlassGroup {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: MeetingMetrics.noticeGap) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: MeetingMetrics.noticeIcon, height: MeetingMetrics.noticeIcon)
                            .accessibilityHidden(true)
                    }
                    Text("\(appName) call")
                        .font(Typeface.pill)
                        .foregroundStyle(Color.pillText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: MeetingMetrics.noticeLine, alignment: .leading)
                    PillTextButton(title: "Start", label: "Start recording \(appName) call") { Task { await meeting.start() } }
                    PillIconButton(
                        symbol: "xmark", label: "Dismiss", size: MeetingMetrics.dismissSymbol, ink: .pillMuted,
                        hoverWash: MeetingMetrics.dismissWash
                    ) { meeting.dismissOffer() }
                }
                if let event {
                    Text(event)
                        .font(Typeface.small)
                        .foregroundStyle(Color.pillMuted)
                        .lineLimit(MeetingMetrics.noticeTitleLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, MeetingMetrics.noticeTitleTop)
                        .padding(.trailing, MeetingMetrics.noticeTitleTrailing)
                }
            }
            .padding(EdgeInsets(
                top: padding.top, leading: padding.leading, bottom: event == nil ? padding.top : padding.bottom, trailing: padding.trailing
            ))
            .frame(width: MeetingMetrics.noticeWidth)
            .modifier(PillSurface(radius: MeetingMetrics.noticeRadius, depth: .plate, id: "notice", glass: glass))
        }
        .environment(\.colorScheme, .dark)
        .environment(\.pillLook, look)
    }
}
