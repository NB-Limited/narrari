import NarrariKit
import SwiftUI

extension EnvironmentValues {
    @Entry var pillLook = PillSettings.look.defaultValue
    // The settings preview sits inside a window, so the macOS 15 material blends with the page, not the desktop.
    @Entry var pillWithinWindow = false
}

struct PillGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: PillMetrics.glassSpacing) { content }
        } else {
            content
        }
    }
}

enum PillDepth {
    case capsule
    case plate
}

// Each finish has its own file; Increase Contrast overrides them all.
struct PillSurface: ViewModifier {
    let radius: CGFloat
    let depth: PillDepth
    let id: String
    let glass: Namespace.ID

    @Environment(\.pillLook) private var look
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        if contrast == .increased {
            content.background {
                shape.fill(Color.pillFill)
                    .overlay { shape.stroke(PillMetrics.contrastOuterEdge, lineWidth: 2 * PillMetrics.contrastEdgeWidth) }
                    .overlay { shape.strokeBorder(PillMetrics.contrastInnerEdge, lineWidth: PillMetrics.contrastEdgeWidth) }
                    .modifier(PillShadow(depth: depth))
            }
        } else {
            switch look.finish(reduceTransparency: reduceTransparency) {
            case .smoked: content.modifier(SmokedSurface(shape: shape, depth: depth, id: id, glass: glass))
            case .clear: content.modifier(ClearSurface(shape: shape, depth: depth, id: id, glass: glass))
            case .solid: content.modifier(SolidSurface(shape: shape, depth: depth))
            case .gloss: content.modifier(GlossSurface(shape: shape, depth: depth))
            }
        }
    }
}

struct PillShadow: ViewModifier {
    let depth: PillDepth

    func body(content: Content) -> some View {
        let shadow = depth == .capsule ? PillMetrics.capsuleShadow : PillMetrics.plateShadow
        content
            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
            .shadow(color: .black.opacity(shadow.contact), radius: 1, y: 1)
    }
}
