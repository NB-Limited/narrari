import Foundation

// The Halo look's light on the capsule's outline. Positions are fractions of the outline's length, walked clockwise
// from the bottom centre, so the top centre sits at one half and equal fractions are equal distances.
public enum Halo {
    public static let top = 0.5

    public static func perimeter(width: CGFloat, height: CGFloat) -> CGFloat {
        let diameter = min(width, height)
        return 2 * (width - diameter) + .pi * diameter
    }

    // Loudness is the level on the bars' curve, 0 in silence to 1 at full level.
    public static func lineLength(loudness: Double) -> CGFloat {
        let loudness = CGFloat(min(max(loudness, 0), 1))
        return PillGeometry.haloShortest + (PillGeometry.haloLongest - PillGeometry.haloShortest) * loudness
    }

    // While recording: one line centred on the top edge.
    public static func line(loudness: Double, perimeter: CGFloat) -> ClosedRange<Double> {
        let half = Double(min(lineLength(loudness: loudness), perimeter) / perimeter) / 2
        return (top - half)...(top + half)
    }

    // While working: a segment ending at its head, which leaves the top centre and laps once per haloLap.
    public static func lap(at seconds: Double, perimeter: CGFloat) -> ClosedRange<Double> {
        let head = top + max(0, seconds) / PillMotion.haloLap
        return (head - Double(min(PillGeometry.haloSegment, perimeter) / perimeter))...head
    }

    // Done: the share of the outline lit from the top centre, and its brightness. Reduce Motion lights it all at once.
    public static func done(at seconds: Double, reduceMotion: Bool) -> (lit: Double, brightness: Double) {
        let seconds = max(0, seconds)
        let lit = reduceMotion ? 1 : min(1, seconds / PillMotion.haloDraw)
        let brightness = max(0, min(1, 1 - (seconds - PillMotion.haloDraw) / PillMotion.haloFade))
        return (lit, brightness)
    }

    // A path trims only within one walk of the outline, so a stretch past either end is split there.
    public static func spans(_ stretch: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard stretch.upperBound - stretch.lowerBound < 1 else { return [0...1] }
        let start = stretch.lowerBound - stretch.lowerBound.rounded(.down)
        let end = start + stretch.upperBound - stretch.lowerBound
        return end <= 1 ? [start...end] : [start...1, 0...(end - 1)]
    }
}
