import NarrariKit
import SwiftUI

// The Halo look: light on the capsule's outline. A line on the top edge follows the level while recording, a segment
// laps the outline while working, and the outline draws once when done. Notices and errors carry no light.
struct HaloRim: View {
    let capsule: PillCapsule
    let isListening: Bool

    @Environment(\.reducesMotion) private var reduceMotion

    private enum Phase {
        case line
        case lap
        case done
        case dark
    }

    var body: some View {
        ZStack {
            switch Self.phase(of: capsule) {
            case .line:
                HaloLine(isListening: isListening)
            case .lap where reduceMotion:
                Canvas { context, size in
                    RimLight.draw([0...1], brightness: PillMetrics.haloSteady, on: RimLight.outline(in: size), in: context)
                }
            case .lap:
                RimClock { seconds in
                    Canvas { context, size in
                        let stretch = Halo.lap(at: seconds, perimeter: RimLight.perimeter(of: size))
                        RimLight.draw(stretch, profile: RimLight.comet, on: RimLight.outline(in: size), in: context)
                    }
                }
            case .done:
                // Shown for the done hold only, so the clock stops with the pill.
                RimClock { [reduceMotion] seconds in
                    Canvas { context, size in
                        let done = Halo.done(at: seconds, reduceMotion: reduceMotion)
                        guard done.brightness > 0 else { return }
                        let spans = Halo.spans(Halo.top...(Halo.top + done.lit))
                        RimLight.draw(spans, brightness: done.brightness, on: RimLight.outline(in: size), in: context)
                    }
                }
            case .dark:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
    }

    private static func phase(of capsule: PillCapsule) -> Phase {
        switch capsule {
        case .recording: .line
        case .working: .lap
        case .done: .done
        case .notice: .dark
        }
    }
}

// Seconds since this phase began: each phase is its own view, so its clock starts when it appears.
private struct RimClock<Content: View>: View {
    @ViewBuilder let content: (Double) -> Content

    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation) { timeline in
            content(timeline.date.timeIntervalSince(start))
        }
    }
}

// Samples the level on the bars' beat and moves between samples as they do, so it redraws only the line.
private struct HaloLine: View {
    let isListening: Bool

    @State private var follower = LevelFollower()
    @Environment(\.pillLevel) private var level

    var body: some View {
        TimelineView(.animation(minimumInterval: LevelMeter.sampleInterval, paused: !isSampling)) { timeline in
            let loudness = loudness(at: timeline.date)
            LitLine(loudness: loudness)
                .animation(
                    isListening ? .linear(duration: LevelMeter.sampleInterval) : .spring(PillStage.spring(PillMotion.foldSpring)),
                    value: loudness
                )
        }
        .onChange(of: isListening) { _, isListening in
            if isListening { follower.restart() }
        }
    }

    private var isSampling: Bool {
        guard isListening, case .live = level else { return false }
        return true
    }

    private func loudness(at date: Date) -> Double {
        guard isListening else { return 0 }
        switch level {
        case .live(let input):
            return follower.loudness(following: input(), at: date.timeIntervalSinceReferenceDate)
        case .held(let bars):
            return bars.map(\.height).max() ?? 0
        }
    }
}

private struct LitLine: View, Animatable {
    var loudness: Double

    nonisolated var animatableData: Double {
        get { loudness }
        set { loudness = newValue }
    }

    var body: some View {
        Canvas { [loudness] context, size in
            let stretch = Halo.line(loudness: loudness, perimeter: RimLight.perimeter(of: size))
            RimLight.draw(stretch, profile: RimLight.softEnds, brightness: PillMetrics.haloQuiet + (1 - PillMetrics.haloQuiet) * loudness,
                          on: RimLight.outline(in: size), in: context)
        }
    }
}

enum RimLight {
    // The capsule's outline at the line's centre, from the bottom centre clockwise, as Halo measures it.
    static func outline(in size: CGSize) -> Path {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: PillGeometry.haloWidth / 2, dy: PillGeometry.haloWidth / 2)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.midY), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.midY), radius: radius,
                    startAngle: .degrees(270), endAngle: .degrees(450), clockwise: false)
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }

    static func perimeter(of size: CGSize) -> CGFloat {
        Halo.perimeter(width: size.width - PillGeometry.haloWidth, height: size.height - PillGeometry.haloWidth)
    }

    // Brightness along a stretch, tail at 0 and head at 1.
    static let softEnds = [(0.0, 0.0), (0.3, 1.0), (0.7, 1.0), (1.0, 0.0)]
    static let comet = [(0.0, 0.0), (0.8, 1.0), (1.0, 0.0)]

    // The fade runs from the tail to the head in a straight line; a stretch shorter than half the capsule's end never
    // doubles back along that line, so its ends fade on the curve too.
    static func draw(_ stretch: ClosedRange<Double>, profile: [(Double, Double)], brightness: Double = 1, on outline: Path, in context: GraphicsContext) {
        let lit = path(Halo.spans(stretch), on: outline)
        let tail = point(at: stretch.lowerBound, on: outline)
        let head = point(at: stretch.upperBound, on: outline)
        stroke(lit, in: context) { opacity in
            .linearGradient(
                Gradient(stops: profile.map { .init(color: Color.pillText.opacity($0.1 * opacity * brightness), location: $0.0) }),
                startPoint: tail, endPoint: head
            )
        }
    }

    static func draw(_ spans: [ClosedRange<Double>], brightness: Double, on outline: Path, in context: GraphicsContext) {
        stroke(path(spans, on: outline), in: context) { .color(Color.pillText.opacity($0 * brightness)) }
    }

    // The glow is wider than the line and centred on it, so the capsule's clip keeps it on the glass.
    private static func stroke(_ lit: Path, in context: GraphicsContext, shading: (Double) -> GraphicsContext.Shading) {
        for glow in PillMetrics.haloGlow {
            context.stroke(lit, with: shading(glow.opacity), style: StrokeStyle(lineWidth: glow.width))
        }
        context.stroke(lit, with: shading(1), style: StrokeStyle(lineWidth: PillGeometry.haloWidth))
    }

    private static func path(_ spans: [ClosedRange<Double>], on outline: Path) -> Path {
        var lit = Path()
        for span in spans { lit.addPath(outline.trimmedPath(from: span.lowerBound, to: span.upperBound)) }
        return lit
    }

    private static func point(at fraction: Double, on outline: Path) -> CGPoint {
        let fraction = fraction - fraction.rounded(.down)
        return outline.trimmedPath(from: 0, to: max(fraction, 0.000_1)).currentPoint ?? .zero
    }
}
