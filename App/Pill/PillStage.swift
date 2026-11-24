import AppKit
import NarrariKit
import SwiftUI

struct PillMeter: Equatable {
    var seconds = 0
    var isListening = true
}

extension PillWidths {
    @MainActor static let app = PillWidths(
        label: { ceil(($0 as NSString).size(withAttributes: [.font: Typeface.pillFont]).width) },
        timer: { ceil(($0 as NSString).size(withAttributes: [.font: Typeface.pillTimerFont]).width * 2) / 2 }
    )
}

struct PillStage: View {
    let state: PillState
    let meter: PillMeter
    let look: PillLook
    let colour: PillColour
    // A meeting recording while this dictation runs waits as a circle beside the capsule.
    let isMeetingFolded: Bool

    @State private var capsule: PillCapsule
    // Measured when the stage appears, not in init: the stage is built again on every update of the pill.
    @State private var width: CGFloat?
    @State private var words: CGFloat?
    @State private var change: PillChange?
    @State private var releases = 0
    @Namespace private var glass
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.reducesMotion) private var reduceMotion

    init(state: PillState, meter: PillMeter, look: PillLook, colour: PillColour, isMeetingFolded: Bool = false) {
        self.state = state
        self.meter = meter
        self.look = look
        self.colour = colour
        self.isMeetingFolded = isMeetingFolded
        _capsule = State(initialValue: state.capsule)
    }

    var body: some View {
        PillGlassGroup {
            VStack(spacing: PillGeometry.captionGap) {
                ZStack(alignment: .bottom) {
                    CaptionPlate(
                        text: look.hasPlate ? state.caption : nil,
                        exit: PillChange.captionExit(to: state.capsule),
                        isDimmed: !state.capsule.isRecording,
                        glass: glass
                    )
                    SilencePlate(microphone: state.silentMicrophone, glass: glass)
                }
                capsuleView
                    .overlay(alignment: .leading) {
                        if isMeetingFolded { FoldedMeeting(glass: glass).offset(x: -MeetingMetrics.foldReach) }
                    }
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.pillLook, look)
        .accessibilityHidden(true)
        .onAppear {
            words = wordsWidth
            width = capsuleWidth
        }
        .onChange(of: state.capsule) { _, new in show(new) }
        .onChange(of: meter.seconds) { _, seconds in resize(seconds: seconds) }
        .onChange(of: state.caption) { _, caption in
            guard look.recorder == .words else { return }
            words = Self.words(caption, grown: wordsWidth, look: look)
            resize()
        }
        .onChange(of: look) { _, look in
            let words = Self.words(state.caption, grown: 0, look: look)
            self.words = words
            width = Self.width(of: capsule, seconds: meter.seconds, look: look, words: words)
        }
        .onChange(of: meter.isListening) { _, isListening in
            if !isListening, !reduceMotion { releases += 1 }
        }
    }

    private var capsuleView: some View {
        CrossFade(value: Self.layer(of: capsule), timing: timing(outDelay: change?.outDelay ?? 0)) { layer, leading in
            content(of: layer, leading: leading)
                .environment(\.pillAccent, look.isColoured ? PillAccent.colour(of: layer, listening: colour.color(highContrast: contrast == .increased)) : nil)
        }
        .modifier(CapsuleFrame(width: capsuleWidth, glass: glass) {
            if look.hasHalo { HaloRim(capsule: capsule, isListening: meter.isListening) }
        })
        .keyframeAnimator(initialValue: 1.0, trigger: releases) { content, scale in
            content.scaleEffect(scale, anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(PillMotion.pressScale, duration: PillMotion.pressDown)
            SpringKeyframe(1, duration: PillMotion.pressUpSpring.duration, spring: Self.spring(PillMotion.pressUpSpring))
        }
    }

    @ViewBuilder
    private func content(of layer: PillCapsule, leading: Bool) -> some View {
        switch layer {
        case .recording:
            RecordingLayer(
                slot: slot, meter: meter, timing: timing(outDelay: 0),
                recorder: look.recorder, words: state.caption, wordsWidth: wordsWidth
            )
        case .working(let label):
            Placed(leading: leading) {
                if look.recorder == .bars {
                    WorkingDots()
                } else {
                    HStack(spacing: 0) {
                        PillSymbol(name: label.symbol)
                        Text(label.text).fixedSize().onPillBaseline().padding(.leading, PillGeometry.symbolGap)
                        WorkingDots().restsOnPillBaseline().padding(.leading, PillGeometry.dotsGap)
                    }
                }
            }
        case .notice(let label):
            Placed(leading: leading) {
                HStack(spacing: PillGeometry.symbolGap) {
                    PillSymbol(name: label.symbol, isError: label.isError)
                    Text(label.text)
                        .lineLimit(1)
                        .frame(width: min(PillWidths.app.labelWidth(label.text), PillWidths.noticeTextMax), alignment: .leading)
                        .onPillBaseline()
                }
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: PillMetrics.check, weight: .semibold))
                .foregroundStyle(look.isColoured ? Color.pillDone : Color.pillText)
                .transition(checkTransition)
        }
    }

    private var wordsWidth: CGFloat {
        words ?? Self.words(state.caption, grown: 0, look: look)
    }

    private var capsuleWidth: CGFloat {
        width ?? Self.width(of: capsule, seconds: meter.seconds, look: look, words: wordsWidth)
    }

    private var slot: PillLabel? {
        if case .recording(let slot) = capsule { return slot }
        return nil
    }

    private static func layer(of capsule: PillCapsule) -> PillCapsule {
        capsule.isRecording ? .recording(slot: nil) : capsule
    }

    private var checkTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        if #available(macOS 26.0, *) { return AnyTransition(.symbolEffect(.drawOn)) }
        return AnyTransition(.symbolEffect(.appear))
    }

    private func timing(outDelay: Double) -> FadeTiming {
        let inDelay = change?.inDelay ?? 0
        return FadeTiming(
            out: (reduceMotion ? Self.reducedCurve : Self.outCurve).delay(outDelay),
            in: (reduceMotion ? Self.reducedCurve : Self.inCurve).delay(inDelay),
            leading: change?.revealsFromLeading ?? false,
            blur: reduceMotion ? 0 : PillMotion.swapBlur
        )
    }

    private func resize(seconds: Int? = nil) {
        let target = Self.width(of: capsule, seconds: seconds ?? meter.seconds, look: look, words: wordsWidth)
        guard target != capsuleWidth else { return }
        withAnimation(Self.widthSpring) { width = target }
    }

    private static func width(of capsule: PillCapsule, seconds: Int, look: PillLook, words: CGFloat) -> CGFloat {
        PillWidths.app.width(of: capsule, seconds: seconds, recorder: look.recorder, words: words)
    }

    private static func words(_ caption: String?, grown: CGFloat, look: PillLook) -> CGFloat {
        guard look.recorder == .words, let caption else { return 0 }
        let newest = Caption.lastWords(of: caption, widerThan: PillGeometry.inlineWordsMax, measure: CaptionPlate.naturalWidth)
        return PillWidths.inlineWords(natural: CaptionPlate.naturalWidth(newest), grown: grown)
    }

    private func show(_ new: PillCapsule) {
        let target = Self.width(of: new, seconds: meter.seconds, look: look, words: wordsWidth)
        let plan = PillChange(from: capsule, to: new, widths: (capsuleWidth, target), reduceMotion: reduceMotion)
        change = plan
        capsule = new
        // A zero-length animation drops its delay, so the Reduce Motion jump is one millisecond long.
        let move: Animation = plan.width == .spring ? Self.widthSpring : .linear(duration: 0.001)
        withAnimation(move.delay(plan.widthDelay)) { width = target }
    }

    static func spring(_ spring: (duration: Double, bounce: Double)) -> Spring {
        Spring(duration: spring.duration, bounce: spring.bounce)
    }

    private static let widthSpring = Animation.spring(spring(PillMotion.widthSpring))
    private static let outCurve = Motion.Curve.exit.animation(duration: PillMotion.out)
    private static let inCurve = Motion.Curve.enter.animation(duration: PillMotion.in)
    private static let reducedCurve = Animation.linear(duration: PillMotion.reduced)
}

// Animated here, not by layout, so content arriving mid-change is laid out against each frame's width.
private struct CapsuleFrame<Rim: View>: ViewModifier, Animatable {
    var width: CGFloat
    let glass: Namespace.ID
    @ViewBuilder let rim: Rim

    nonisolated var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        content
            .font(Typeface.pill)
            .foregroundStyle(Color.pillText)
            .frame(width: width, height: PillGeometry.height)
            .overlay { rim }
            .clipShape(Capsule())
            .modifier(PillSurface(radius: PillGeometry.height / 2, depth: .capsule, id: "capsule", glass: glass))
    }
}

private struct Placed<Content: View>: View {
    let leading: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .fixedSize()
            .padding(.horizontal, PillGeometry.padding)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: leading ? .leading : .center)
            .mask {
                if leading {
                    TrailingFade(feather: PillGeometry.revealFeather, clearance: PillGeometry.revealClearance)
                } else {
                    Rectangle()
                }
            }
    }
}

extension View {
    func onPillBaseline() -> some View {
        let below = Typeface.pillBaselineBelowCenter
        return alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - below }
    }

    func restsOnPillBaseline() -> some View {
        let below = Typeface.pillBaselineBelowCenter
        return alignmentGuide(VerticalAlignment.center) { $0[.bottom] - below }
    }
}
