import NarrariKit
import SwiftUI

// The plate above the capsule, saying the microphone delivers nothing; it shows in every look, also with live text off.
struct SilencePlate: View {
    let microphone: String?
    let glass: Namespace.ID

    static let lead = "No sound from"
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let microphone {
                plate(microphone)
                    .transition(.asymmetric(insertion: appear, removal: leave))
            }
        }
    }

    private func plate(_ microphone: String) -> some View {
        let height = Caption.plateHeight(lines: 1)
        let radius = Caption.plateRadius(height: height)
        return HStack(spacing: PillMetrics.plateSymbolGap) {
            Image(systemName: "waveform.slash")
                .font(.system(size: PillMetrics.plateSymbol))
            HStack(spacing: Typeface.captionSpace) {
                Text(Self.lead)
                    .fixedSize()
                Text(microphone)
                    .truncationMode(.middle)
            }
            .font(Typeface.caption)
            .lineLimit(1)
        }
        .frame(maxWidth: PillGeometry.captionMeasure)
        .fixedSize()
        .foregroundStyle(Color.pillText)
        .padding(.horizontal, PillGeometry.captionPaddingX)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
        .modifier(PillSurface(radius: radius, depth: .plate, id: "silence", glass: glass))
    }

    private var appear: AnyTransition {
        guard !reduceMotion else { return AnyTransition.opacity.animation(.linear(duration: PillMotion.reduced)) }
        return AnyTransition.scale(scale: PillMotion.captionAppearScale, anchor: .bottom)
            .combined(with: .offset(y: PillMotion.appearRise))
            .combined(with: .opacity)
            .animation(.spring(PillStage.spring(PillMotion.captionAppearSpring)))
    }

    private var leave: AnyTransition {
        AnyTransition.opacity.animation(
            reduceMotion ? .linear(duration: PillMotion.reduced) : Motion.Curve.exit.animation(duration: PillMotion.captionFade)
        )
    }
}
