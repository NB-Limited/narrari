import Foundation

// Content never outgrows its shape: shrinking, it leaves before the shape moves; growing, it is revealed by the edge.
public struct PillChange: Sendable, Equatable {
    public enum Width: Sendable, Equatable {
        case spring
        case step
    }

    public enum CaptionExit: Sendable, Equatable {
        case lift
        case fade
    }

    public let outDelay: TimeInterval
    public let widthDelay: TimeInterval
    public let width: Width
    public let inDelay: TimeInterval
    public let revealsFromLeading: Bool

    public init(from old: PillCapsule, to new: PillCapsule, widths: (from: CGFloat, to: CGFloat), reduceMotion: Bool) {
        let beat = old.isRecording && !new.isRecording ? PillMotion.releaseBeat : 0
        let grows = widths.to >= widths.from
        outDelay = beat
        revealsFromLeading = grows && !reduceMotion
        if reduceMotion {
            width = .step
            widthDelay = beat + PillMotion.reduced
            inDelay = beat + PillMotion.reduced
        } else if grows {
            // The recording layer is pinned to both edges, so the capsule may start widening at the release itself.
            width = .spring
            widthDelay = 0
            inDelay = beat + PillMotion.inDelay
        } else {
            width = .spring
            widthDelay = beat + PillMotion.out
            inDelay = beat + PillMotion.out
        }
    }

    public static func captionExit(to capsule: PillCapsule?) -> CaptionExit {
        capsule == .done ? .lift : .fade
    }
}

// Seconds; springs are (duration, bounce) as in SwiftUI's spring(duration:bounce:).
public enum PillMotion {
    public static let appearSpring = (duration: 0.42, bounce: 0.12)
    public static let appearScale = 0.86
    public static let appearRise: CGFloat = 6
    public static let appearFade = 0.16
    public static let leave = 0.24
    public static let leaveScale = 0.9

    public static let widthSpring = (duration: 0.32, bounce: 0.0)
    public static let out = 0.10
    public static let swapBlur: CGFloat = 3
    public static let inDelay = 0.04
    public static let `in` = 0.20

    public static let releaseBeat = 0.12
    public static let pressDown = 0.07
    public static let pressScale = 0.965
    public static let pressUpSpring = (duration: 0.3, bounce: 0.0)
    public static let foldSpring = (duration: 0.2, bounce: 0.0)

    public static let dotsPeriod = 0.95
    public static let dotsStagger = 0.16
    public static let dotsLow = 0.35
    public static let dotsReduced = 0.6

    public static let captionAppearSpring = (duration: 0.4, bounce: 0.1)
    public static let captionAppearScale = 0.92
    public static let captionWidthSpring = (duration: 0.24, bounce: 0.0)
    public static let captionLineSpring = (duration: 0.36, bounce: 0.0)
    public static let wordDelay = 0.06
    public static let wordFade = 0.18
    public static let wordStagger = 0.03
    public static let wordStaggerSteps = 3
    public static let fitSlack: CGFloat = 3
    public static let wordBlur: CGFloat = 2
    public static let scrollFade = 0.45
    public static let captionDim = 0.8
    public static let captionDimDuration = 0.18
    public static let captionLift: CGFloat = 6
    public static let captionLiftScale = 0.94
    public static let captionLiftDuration = 0.18
    public static let captionTextOut = 0.10
    public static let captionFade = 0.2
    public static let captionSettled = 0.66
    public static let captionSettle = 0.5

    public static let haloLap = 1.2
    public static let haloDraw = 0.4
    public static let haloFade = 0.25

    public static let reduced = 0.15
}

extension PillMotion {
    // The working dots: a wave from dotsLow to full running through the three, each a stagger behind the one before.
    public static func dotOpacity(_ index: Int, at time: TimeInterval) -> Double {
        let phase = (time / dotsPeriod - Double(index) * dotsStagger).truncatingRemainder(dividingBy: 1)
        let wave = sin(.pi * (phase < 0 ? phase + 1 : phase))
        return dotsLow + (1 - dotsLow) * wave * wave
    }
}
