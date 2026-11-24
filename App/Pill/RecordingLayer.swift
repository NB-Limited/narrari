import AppKit
import NarrariKit
import SwiftUI

// The capsule while recording. Past the level bars sits the slot: a notice, or for the words recorder the words heard.
struct RecordingLayer: View {
    let slot: PillLabel?
    let meter: PillMeter
    let timing: FadeTiming
    let recorder: PillRecorder
    let words: String?
    let wordsWidth: CGFloat

    var body: some View {
        let isFull = recorder == .full
        HStack(spacing: 0) {
            if isFull {
                PillSymbol(name: "mic.fill").padding(.trailing, PillGeometry.recordingGap)
            }
            LevelBars(isListening: meter.isListening)
            CrossFade(value: slot, timing: timing) { slot, _ in
                if let slot {
                    HStack(spacing: PillGeometry.slotGap) {
                        PillSymbol(name: slot.symbol, isError: slot.isError)
                        Text(slot.text)
                            .lineLimit(1)
                            .frame(
                                width: min(
                                    PillWidths.app.labelWidth(slot.text),
                                    PillWidths.app.slotTextMax(seconds: meter.seconds, recorder: recorder)
                                ),
                                alignment: .leading
                            )
                            .onPillBaseline()
                    }
                    .fixedSize()
                    .environment(\.pillAccent, nil)
                } else if recorder == .words, let words {
                    InlineWords(text: words, width: wordsWidth)
                }
            }
            .padding(.leading, PillGeometry.recordingGap)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            // Without a timer the trailing padding joins the slot, so its soft edge stays inside the capsule.
            .padding(.trailing, isFull ? 0 : PillGeometry.padding)
            .mask { TrailingFade(feather: PillGeometry.slotFeather, clearance: PillGeometry.slotClearance) }
            if isFull {
                Text(PillWidths.timerText(seconds: meter.seconds))
                    .font(Typeface.pillTimer)
                    .foregroundStyle(Color.pillMuted)
                    .frame(width: PillWidths.app.timerWidth(seconds: meter.seconds), alignment: .leading)
                    .onPillBaseline()
            }
        }
        .padding(.leading, PillGeometry.padding)
        .padding(.trailing, isFull ? PillGeometry.padding : 0)
    }
}

// One line; once the words outgrow it the newest stay in view and the oldest fade off the leading edge.
private struct InlineWords: View {
    let text: String
    let width: CGFloat

    var body: some View {
        let newest = Caption.lastWords(of: text, widerThan: PillGeometry.inlineWordsMax, measure: CaptionPlate.naturalWidth)
        let overflows = CaptionPlate.naturalWidth(newest) > width
        Text(verbatim: String(newest))
            .font(Typeface.caption)
            .foregroundStyle(Color.pillText)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, alignment: overflows ? .trailing : .leading)
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflows ? PillMetrics.inlineFeather : 0)
                    Rectangle()
                }
            }
            .onPillBaseline()
    }
}

struct PillSymbol: View {
    let name: String
    var isError = false

    @Environment(\.pillAccent) private var accent

    var body: some View {
        Image(systemName: name)
            .font(.system(size: PillGeometry.symbol))
            .foregroundStyle(isError ? Color.pillError : accent ?? Color.pillText)
            .frame(width: PillGeometry.symbol)
    }
}

// Where the bars read the input level: live, sampled on the bars' own beat, or one held frame.
enum PillLevel: Sendable {
    case live(@MainActor @Sendable () -> Float)
    case held([LevelMeter.Bar])
}

extension EnvironmentValues {
    @Entry var pillLevel = PillLevel.held(LevelMeter.folded)
}

// Only this view reads the level, so a sample redraws the bars and nothing else.
struct LevelBars: View {
    let isListening: Bool

    @State private var follower = LevelFollower()
    @Environment(\.pillLevel) private var level
    @Environment(\.pillAccent) private var accent
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: LevelMeter.sampleInterval, paused: !isSampling)) { context in
            let bars = bars(at: context.date)
            HStack(spacing: PillGeometry.barGap) {
                ForEach(bars.indices, id: \.self) { index in
                    Capsule()
                        .frame(
                            width: PillGeometry.barWidth,
                            height: PillGeometry.barMinHeight
                                + (PillGeometry.barMaxHeight - PillGeometry.barMinHeight) * bars[index].height
                        )
                        .opacity(bars[index].opacity)
                }
            }
            .frame(height: PillGeometry.barMaxHeight)
            .foregroundStyle(accent ?? Color.pillText)
            .animation(
                isListening ? .linear(duration: LevelMeter.sampleInterval) : .spring(PillStage.spring(PillMotion.foldSpring)),
                value: bars
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

    private func bars(at date: Date) -> [LevelMeter.Bar] {
        guard isListening else { return LevelMeter.folded }
        switch level {
        case .live(let input):
            return follower.bars(following: input(), at: date.timeIntervalSinceReferenceDate, breathing: !reduceMotion)
        case .held(let bars):
            return bars
        }
    }
}
