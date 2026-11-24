import NarrariKit
import SwiftUI

struct WorkingDots: View {
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.pillAccent) private var accent

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: PillGeometry.dotGap) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: PillGeometry.dot, height: PillGeometry.dot)
                        .opacity(reduceMotion ? PillMotion.dotsReduced : PillMotion.dotOpacity(index, at: time))
                }
            }
            .foregroundStyle(accent ?? Color.pillText)
        }
    }
}
