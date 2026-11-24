import SwiftUI

// True black under a soft top sheen, with a fine luminous edge brightest along the top, so the shape still reads over a black page.
struct GlossSurface: ViewModifier {
    let shape: RoundedRectangle
    let depth: PillDepth

    func body(content: Content) -> some View {
        content.background {
            shape.fill(Color.pillBlack)
                .overlay {
                    shape.fill(LinearGradient(
                        stops: PillMetrics.glossSheen.map { .init(color: .white.opacity($0.1), location: $0.0) },
                        startPoint: .top, endPoint: .bottom
                    ))
                }
                .overlay { Rim(shape: shape, stops: PillMetrics.glossEdge, width: PillMetrics.glossEdgeWidth) }
                .modifier(PillShadow(depth: depth))
        }
    }
}
