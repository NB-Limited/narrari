import SwiftUI

struct SolidSurface: ViewModifier {
    let shape: RoundedRectangle
    let depth: PillDepth

    func body(content: Content) -> some View {
        content.background {
            shape.fill(Color.pillFill)
                .overlay { shape.strokeBorder(PillMetrics.solidEdge, lineWidth: PillMetrics.rimWidth) }
                .modifier(PillShadow(depth: depth))
        }
    }
}
