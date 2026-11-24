import AppKit
import SwiftUI

struct SmokedSurface: ViewModifier {
    let shape: RoundedRectangle
    let depth: PillDepth
    let id: String
    let glass: Namespace.ID

    func body(content: Content) -> some View {
        let tint = depth == .capsule ? PillMetrics.capsuleTint : PillMetrics.plateTint
        let smoke = depth == .capsule ? PillMetrics.capsuleSmoke : PillMetrics.plateSmoke
        if #available(macOS 26.0, *) {
            content
                .background { shape.fill(Color.pillFill.opacity(smoke)).overlay { Rim(shape: shape, stops: PillMetrics.rim) } }
                .glassEffect(.regular.tint(Color.pillFill.opacity(tint)), in: shape)
                .glassEffectID(id, in: glass)
                .glassEffectTransition(.materialize)
        } else {
            content.background {
                ZStack {
                    PillMaterial(radius: shape.cornerSize.width)
                    shape.fill(Color.pillFill.opacity(smoke)).modifier(PillShadow(depth: depth))
                    Rim(shape: shape, stops: PillMetrics.rim)
                }
            }
        }
    }
}

// No outer hairline: on a light ground any line outside the dark glass reads as a pale ring.
struct Rim: View {
    let shape: RoundedRectangle
    let stops: [(Double, Double)]
    var width = PillMetrics.rimWidth

    var body: some View {
        shape.strokeBorder(
            LinearGradient(
                stops: stops.map { .init(color: .white.opacity($0.1), location: $0.0) },
                startPoint: .top, endPoint: .bottom
            ),
            lineWidth: width
        )
    }
}

struct PillMaterial: NSViewRepresentable {
    let radius: CGFloat

    @Environment(\.pillWithinWindow) private var withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.maskImage = MenuPanelBackground.cornerMask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        guard view.maskImage?.capInsets.top != radius else { return }
        view.maskImage = MenuPanelBackground.cornerMask(radius: radius)
    }
}
