import NarrariKit
import SwiftUI

// A sidebar list's first read: "Loading" until it ends, or the form error with Try again under it.
struct ListLoad: View {
    let state: WorkState
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            if let problem = state.problem {
                FormError(message: problem.message)
                if problem.canRetry {
                    Button("Try again", action: onRetry).buttonStyle(.secondary)
                }
            } else {
                WorkLine(state: state).font(Typeface.small)
            }
        }
        .padding(EdgeInsets(top: Space.s10, leading: Space.s8, bottom: Space.s10, trailing: Space.s8))
    }
}
