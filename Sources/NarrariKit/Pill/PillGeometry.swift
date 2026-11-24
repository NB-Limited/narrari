import Foundation

public enum PillGeometry {
    public static let height: CGFloat = 36
    public static let padding: CGFloat = 14
    public static let symbol: CGFloat = 15
    public static let symbolGap: CGFloat = 8
    public static let recordingGap: CGFloat = 10
    public static let slotGap: CGFloat = 7
    public static let dotsGap: CGFloat = 6
    public static let noticeMaxWidth: CGFloat = 400
    public static let doneDiameter: CGFloat = 36
    public static let revealFeather: CGFloat = 8
    public static let revealClearance: CGFloat = 6
    public static let slotFeather: CGFloat = 6
    public static let slotClearance: CGFloat = 4

    public static let barCount = LevelMeter.profile.count
    public static let barWidth: CGFloat = 3
    public static let barGap: CGFloat = 2.5
    public static let barMinHeight: CGFloat = 3
    public static let barMaxHeight: CGFloat = 18
    public static let meterWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

    public static let dot: CGFloat = 3.5
    public static let dotGap: CGFloat = 3
    public static let dotsWidth = 3 * dot + 2 * dotGap

    public static let captionGap: CGFloat = 8
    public static let captionPaddingX: CGFloat = 12
    public static let captionPaddingY: CGFloat = 6.5
    public static let captionLineHeight: CGFloat = 16.5
    public static let captionRadius: CGFloat = 16
    public static let captionMaxWidth: CGFloat = 420
    public static let captionMinWidth: CGFloat = 64
    public static let captionLines = 2
    public static let captionMeasure = captionMaxWidth - 2 * captionPaddingX

    public static let inlineWordsMax: CGFloat = 300

    public static let haloShortest: CGFloat = 10
    public static let haloLongest: CGFloat = 54
    public static let haloSegment: CGFloat = 40
    public static let haloWidth: CGFloat = 1.5
}

public struct PillWidths {
    private let label: (String) -> CGFloat
    private let timer: (String) -> CGFloat

    public init(label: @escaping (String) -> CGFloat, timer: @escaping (String) -> CGFloat) {
        self.label = label
        self.timer = timer
    }

    // Words are the inline words' width, already grown and capped; only the words recorder shows them.
    public func width(of capsule: PillCapsule, seconds: Int = 0, recorder: PillRecorder = .full, words: CGFloat = 0) -> CGFloat {
        switch capsule {
        case .recording(let slot):
            let base = recordingWidth(seconds: seconds, recorder: recorder)
            if let slot {
                return base + PillGeometry.symbol + PillGeometry.slotGap
                    + min(label(slot.text), slotTextMax(seconds: seconds, recorder: recorder)) + PillGeometry.recordingGap
            }
            guard recorder == .words, words > 0 else { return base }
            return base + PillGeometry.recordingGap + words
        case .working(let status):
            guard recorder != .bars else { return PillGeometry.padding + PillGeometry.dotsWidth + PillGeometry.padding }
            return PillGeometry.padding + PillGeometry.symbol + PillGeometry.symbolGap + label(status.text)
                + PillGeometry.dotsGap + PillGeometry.dotsWidth + PillGeometry.padding
        case .notice(let notice):
            return PillGeometry.padding + PillGeometry.symbol + PillGeometry.symbolGap + min(label(notice.text), Self.noticeTextMax) + PillGeometry.padding
        case .done:
            return PillGeometry.doneDiameter
        }
    }

    public func labelWidth(_ text: String) -> CGFloat {
        label(text)
    }

    public static let noticeTextMax = PillGeometry.noticeMaxWidth - 2 * PillGeometry.padding
        - PillGeometry.symbol - PillGeometry.symbolGap

    public func slotTextMax(seconds: Int = 0, recorder: PillRecorder = .full) -> CGFloat {
        PillGeometry.noticeMaxWidth - recordingWidth(seconds: seconds, recorder: recorder) - PillGeometry.symbol
            - PillGeometry.slotGap - PillGeometry.recordingGap
    }

    // Like the caption plate, the words only widen within a dictation; past the cap the oldest scroll away.
    public static func inlineWords(natural: CGFloat, grown: CGFloat) -> CGFloat {
        min(max(natural.rounded(.up), grown), PillGeometry.inlineWordsMax)
    }

    // Tabular figures, so zeros give the box; it grows only when a digit is added.
    public func timerWidth(seconds: Int) -> CGFloat {
        timer(Self.timerText(seconds: seconds).replacing(/[0-9]/, with: "0"))
    }

    public static func timerText(seconds: Int) -> String {
        "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
    }

    private func recordingWidth(seconds: Int, recorder: PillRecorder) -> CGFloat {
        guard recorder == .full else { return PillGeometry.padding + PillGeometry.meterWidth + PillGeometry.padding }
        return PillGeometry.padding + PillGeometry.symbol + PillGeometry.recordingGap + PillGeometry.meterWidth
            + PillGeometry.recordingGap + timerWidth(seconds: seconds) + PillGeometry.padding
    }
}
