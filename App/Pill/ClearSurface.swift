import SwiftUI

struct ClearSurface: ViewModifier {
    let shape: RoundedRectangle
    let depth: PillDepth
    let id: String
    let glass: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background { ClearBody(shape: shape, depth: depth) }
                .glassEffect(.clear.tint(Color.pillFill.opacity(PillMetrics.clearTint)), in: shape)
                .glassEffectID(id, in: glass)
                .glassEffectTransition(.materialize)
        } else {
            content.background {
                ZStack {
                    PillMaterial(radius: shape.cornerSize.width)
                    ClearBody(shape: shape, depth: depth).modifier(PillShadow(depth: depth))
                }
            }
        }
    }
}

// The caption fills its plate top to bottom, so the plate's smoke is even.
private struct ClearBody: View {
    let shape: RoundedRectangle
    let depth: PillDepth

    var body: some View {
        let smoke = depth == .capsule ? PillMetrics.clearSmoke : [(0.0, PillMetrics.clearPlateSmoke)]
        shape
            .fill(LinearGradient(
                stops: smoke.map { .init(color: Color.pillFill.opacity($0.1), location: $0.0) },
                startPoint: .top, endPoint: .bottom
            ))
            .overlay { Rim(shape: shape, stops: PillMetrics.clearRim, width: PillMetrics.clearRimWidth) }
    }
}
