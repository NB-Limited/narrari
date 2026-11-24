import AppKit
import NarrariKit
import SwiftUI

private struct CaptionWord: TextAttribute {
    let index: Int
}

private struct CaptionRenderer: TextRenderer {
    var scroll: Double
    var dim: Double
    let visibleLines: Int
    let firstLine: Int
    let fresh: Range<Int>
    let firstDelay: Double
    let elapsed: Double
    let reduceMotion: Bool
    let settle: CaptionSettle

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(scroll, dim) }
        set { (scroll, dim) = (newValue.first, newValue.second) }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let shift = (max(0, scroll - Double(visibleLines)) - Double(firstLine)) * PillGeometry.captionLineHeight
        for (number, line) in layout.enumerated() {
            let lineOpacity = Caption.lineOpacity(line: firstLine + number, scrolledTo: scroll - 1)
            guard lineOpacity > 0 else { continue }
            for run in line {
                let reveal = run[CaptionWord.self].map { self.reveal($0.index) } ?? 1
                guard reveal > 0 else { continue }
                let brightness = run[CaptionWord.self].map { settle.brightness($0.index, after: elapsed) } ?? 1
                var copy = context
                copy.translateBy(x: 0, y: -shift)
                // The dim after release never takes settled words lower, so they keep their contrast.
                copy.opacity = lineOpacity * reveal * min(brightness, dim)
                if !reduceMotion, reveal < 1 { copy.addFilter(.blur(radius: PillMotion.wordBlur * (1 - reveal))) }
                copy.draw(run)
            }
        }
    }

    private func reveal(_ index: Int) -> Double {
        let progress = Caption.revealProgress(index, fresh: fresh, firstDelay: firstDelay, elapsed: elapsed, reduceMotion: reduceMotion)
        return reduceMotion ? progress : Motion.Curve.enter.unitCurve.value(at: progress)
    }

    // The keyframe runs the elapsed time from 0 to this many seconds, past every word's reveal and settle.
    static let elapsedSpan = 1.0
}

struct CaptionPlate: View {
    let text: String?
    let exit: PillChange.CaptionExit
    let isDimmed: Bool
    let glass: Namespace.ID

    @State private var shown: String?
    @State private var cut = CaptionCut.none
    @State private var fresh = 0..<0
    @State private var updates = 0
    @State private var wordDelay = 0.0
    @State private var grown: CGFloat?
    @State private var lines = 0
    @State private var isLeaving = false
    @State private var wordsGone = false
    @State private var lifts = false
    @State private var settle = CaptionSettle()
    @State private var updatedAt = Date.distantPast
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.pillLook) private var look

    init(text: String?, exit: PillChange.CaptionExit, isDimmed: Bool, glass: Namespace.ID) {
        self.text = text
        self.exit = exit
        self.isDimmed = isDimmed
        self.glass = glass
        _shown = State(initialValue: text)
    }

    var body: some View {
        ZStack {
            if let shown {
                plate(shown)
                    .transition(.asymmetric(insertion: appear, removal: .identity))
            }
        }
        .onChange(of: text) { _, new in update(to: new) }
        .onAppear {
            guard let shown else { return }
            if grown == nil { grown = Self.width(of: shown, grown: 0) }
            settle = CaptionSettle().updated(newest: Self.lastWord(of: shown, after: cut), stopped: [], gap: 0, reduceMotion: reduceMotion)
        }
    }

    private func plate(_ text: String) -> some View {
        let words = Caption.words(Caption.tail(text, after: cut))
        let visible = Caption.visibleLines(lines)
        let grown = grown ?? Self.width(of: text, grown: 0)
        let scroll = Double(max(lines, 1))
        let dim = isDimmed ? PillMotion.captionDim : 1
        let firstLine = cut.lines
        let settle = look.hasHalo ? settle : CaptionSettle()
        return Self.text(words, from: cut.words)
            .font(Typeface.caption)
            .lineSpacing(Typeface.captionLineSpacing)
            .foregroundStyle(Color.pillText)
            .keyframeAnimator(
                initialValue: CaptionRenderer.elapsedSpan, trigger: updates
            ) { [scroll, dim, firstLine, fresh, reduceMotion, wordDelay, settle] content, elapsed in
                content.textRenderer(CaptionRenderer(
                    scroll: scroll, dim: dim, visibleLines: visible, firstLine: firstLine, fresh: fresh,
                    firstDelay: wordDelay, elapsed: elapsed, reduceMotion: reduceMotion, settle: settle
                ))
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(CaptionRenderer.elapsedSpan, duration: CaptionRenderer.elapsedSpan)
            }
            .contentTransition(.identity)
            .fixedSize(horizontal: false, vertical: true)
            .onPreferenceChange(Text.LayoutKey.self) { trim($0.first?.layout) }
            .frame(width: grown, alignment: lines > 1 ? .leading : .center)
            .padding(.top, Typeface.captionTop)
            .opacity(wordsGone ? 0 : 1)
            .animation(
                reduceMotion ? .linear(duration: PillMotion.reduced) : Motion.Curve.enter.animation(duration: PillMotion.captionDimDuration),
                value: isDimmed
            )
            .modifier(PlateFrame(width: grown + 2 * PillGeometry.captionPaddingX, height: Caption.plateHeight(lines: lines), glass: glass))
            .opacity(isLeaving ? 0 : 1)
            .scaleEffect(lifts ? PillMotion.captionLiftScale : 1, anchor: .bottom)
            .offset(y: lifts ? -PillMotion.captionLift : 0)
    }

    private static func text(_ words: [Substring], from first: Int) -> Text {
        words.indices.reduce(Text(verbatim: "")) { text, index in
            let word = Text(verbatim: String(words[index])).customAttribute(CaptionWord(index: first + index))
            return index == 0 ? word : Text("\(text) \(word)")
        }
    }

    // Past the measure the width no longer depends on the words, so they are not measured.
    private static func width(of text: String, grown: CGFloat) -> CGFloat {
        guard grown < PillGeometry.captionMeasure else { return grown }
        return Caption.textWidth(natural: naturalWidth(text), grown: grown)
    }

    static func naturalWidth(_ text: some StringProtocol) -> CGFloat {
        (String(text) as NSString).size(withAttributes: [.font: Typeface.captionFont]).width
    }

    private var appear: AnyTransition {
        if reduceMotion { return .opacity }
        return AnyTransition.scale(scale: PillMotion.captionAppearScale, anchor: .bottom)
            .combined(with: .offset(y: PillMotion.appearRise))
            .combined(with: .opacity)
    }

    private var appearAnimation: Animation {
        reduceMotion ? .linear(duration: PillMotion.reduced) : .spring(PillStage.spring(PillMotion.captionAppearSpring))
    }

    private func update(to new: String?) {
        guard let new else { return leave() }
        if shown == nil || isLeaving {
            isLeaving = false
            wordsGone = false
            lifts = false
            lines = 0
            cut = .none
            grown = Self.width(of: new, grown: 0)
            fresh = Caption.freshWords(from: "", to: new)
            updatedAt = .now
            settle = CaptionSettle().updated(newest: fresh.last ?? 0, stopped: Array(fresh), gap: 0, reduceMotion: reduceMotion)
            wordDelay = 0
            updates = 1
            withAnimation(appearAnimation) { shown = new }
            return
        }
        let old = shown ?? ""
        let current = grown ?? Self.width(of: old, grown: 0)
        let width = Self.width(of: new, grown: current)
        let oldNewest = look.hasHalo ? Self.lastWord(of: old, after: cut) : 0
        if grown == nil { grown = current }
        // One transaction: words committed apart from the width they need are laid out once at the old width, and
        // the lines read from that pass open a line that closes again a frame later.
        withAnimation(reduceMotion || width == current ? nil : .spring(PillStage.spring(PillMotion.captionWidthSpring))) {
            cut = Caption.cut(cut, from: old, to: new)
            fresh = Caption.freshWords(from: old, to: new, after: cut)
            if look.hasHalo {
                let now = Date.now
                settle = settle.updated(
                    newest: Self.lastWord(of: new, after: cut), stopped: [oldNewest] + fresh,
                    gap: now.timeIntervalSince(updatedAt), reduceMotion: reduceMotion
                )
                updatedAt = now
            }
            wordDelay = width > current ? Caption.revealDelay(growth: width - current) : PillMotion.wordDelay
            updates += 1
            shown = new
            grown = width
        }
    }

    private static func lastWord(of text: String, after cut: CaptionCut) -> Int {
        cut.words + Caption.words(Caption.tail(text, after: cut)).count - 1
    }

    // Lines above the last few leave the layout; every later line breaks where it did.
    private func trim(_ layout: Text.Layout?) {
        guard let layout, let shown else { return }
        var previous: Int?
        let starts = layout.map { line -> Int? in
            let first = line.first?[CaptionWord.self]?.index
            defer { previous = line.last?[CaptionWord.self]?.index }
            return first == previous ? nil : first
        }
        // Counted from the cut this layout was made from, before the cut moves on.
        if let count = Caption.lines(shown, at: cut, lineStarts: starts, lastWord: previous) { linesChanged(count) }
        let next = Caption.cut(shown, at: cut, lineStarts: starts, lastWord: previous)
        guard next != cut else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { cut = next }
    }

    private func linesChanged(_ count: Int) {
        guard count != lines else { return }
        let animate = lines > 0 && !reduceMotion
        // A new line opens once the words before it are in, so the plate never shows an empty line.
        let opens = Animation.spring(PillStage.spring(PillMotion.captionLineSpring))
            .delay(count > lines ? Caption.lastRevealStart(firstDelay: wordDelay) : 0)
        withAnimation(animate ? opens : nil) { lines = count }
    }

    // The words leave first, so a half-faded plate never carries half-faded text.
    private func leave() {
        guard shown != nil, !isLeaving else { return }
        let lift = exit == .lift && !reduceMotion
        let plateCurve: Animation = reduceMotion
            ? .linear(duration: PillMotion.reduced)
            : lift ? Motion.Curve.lift.animation(duration: PillMotion.captionLiftDuration)
                : Motion.Curve.exit.animation(duration: PillMotion.captionFade)
        withAnimation(reduceMotion ? .linear(duration: PillMotion.reduced) : Motion.Curve.exit.animation(duration: PillMotion.captionTextOut)) {
            wordsGone = true
        }
        withAnimation(plateCurve) {
            isLeaving = true
            lifts = lift
        } completion: {
            guard isLeaving else { return }
            shown = nil
        }
    }
}

private struct PlateFrame: ViewModifier, Animatable {
    var width: CGFloat
    var height: CGFloat
    let glass: Namespace.ID

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set { (width, height) = (newValue.first, newValue.second) }
    }

    func body(content: Content) -> some View {
        let radius = Caption.plateRadius(height: height)
        content
            .frame(width: width, height: height, alignment: .top)
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: PillMetrics.captionEdgeFeather)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: PillMetrics.captionEdgeFeather)
                }
                .padding(.horizontal, PillMetrics.captionEdgeInset)
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: PillMetrics.captionTopFeather)
                    Rectangle()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
            .modifier(PillSurface(radius: radius, depth: .plate, id: "caption", glass: glass))
    }
}
