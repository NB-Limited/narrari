import CoreGraphics

// Where a floating list or label goes next to the control it belongs to, in screen coordinates with y up.
// It opens below, flips above when there is more room there, and shrinks to the room it has, so it is never off-screen.
public enum AnchoredPlacement {
    public enum Alignment: Sendable {
        case leading
        case center
        case trailing
    }

    public static func frame(
        size: CGSize, anchor: CGRect, gap: CGFloat, alignment: Alignment, within bounds: CGRect
    ) -> CGRect {
        let roomBelow = max(0, anchor.minY - gap - bounds.minY)
        let roomAbove = max(0, bounds.maxY - anchor.maxY - gap)
        let opensBelow = size.height <= roomBelow || roomBelow >= roomAbove
        let height = min(size.height, opensBelow ? roomBelow : roomAbove)
        let width = min(size.width, bounds.width)
        let preferredX = switch alignment {
        case .leading: anchor.minX
        case .center: anchor.midX - width / 2
        case .trailing: anchor.maxX - width
        }
        let x = min(max(preferredX, bounds.minX), bounds.maxX - width)
        let y = opensBelow ? anchor.minY - gap - height : anchor.maxY + gap
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
