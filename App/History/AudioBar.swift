import NarrariKit
import SwiftUI

struct AudioBar: View {
    let playback: AudioPlayback
    var problem: Problem?

    private static let keyStep: TimeInterval = 1

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            if let problem {
                FormError(message: problem.message)
            }
            HStack(spacing: Space.s12) {
                PlayButton(playback: playback)
                    .meetsEdge(.leading)

                Scrubber(playback: playback, keyStep: Self.keyStep)

                Text("\(EntryFormat.position(playback.position)) / \(EntryFormat.position(playback.duration))")
                    .font(Typeface.position)
                    .foregroundStyle(Color.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(EdgeInsets(top: Space.s12, leading: Space.s36, bottom: Space.s16, trailing: Space.s36))
    }
}

private struct Scrubber: View {
    let playback: AudioPlayback
    let keyStep: TimeInterval

    var body: some View {
        let fraction = playback.duration > 0 ? min(playback.position / playback.duration, 1) : 0
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.bar)
                    .fill(Color.selectionFill)
                    .frame(height: WindowMetrics.trackHeight)
                RoundedRectangle(cornerRadius: Radius.bar)
                    .fill(Color.ink)
                    .frame(width: width * fraction, height: WindowMetrics.trackHeight)
                Circle()
                    .fill(Color.ink)
                    .frame(width: WindowMetrics.knob, height: WindowMetrics.knob)
                    .offset(x: width * fraction - WindowMetrics.knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                playback.seek(to: width > 0 ? value.location.x / width : 0)
            })
        }
        .frame(height: ControlMetrics.iconButton)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: playback.skip(by: -keyStep)
            case .right: playback.skip(by: keyStep)
            default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(EntryFormat.position(playback.position)) of \(EntryFormat.position(playback.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.skip(by: keyStep)
            case .decrement: playback.skip(by: -keyStep)
            @unknown default: break
            }
        }
    }
}
