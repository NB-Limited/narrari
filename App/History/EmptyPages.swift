import NarrariKit
import SwiftUI

struct EmptyHistoryPage: View {
    let prompt: EmptyHistory

    var body: some View {
        PagePrompt(said: prompt.said, heard: prompt.heard)
    }
}

struct NoResultsPage: View {
    let query: String

    var body: some View {
        PagePrompt(
            said: "Nothing matches “\(query)”.",
            heard: "Search looks through what was pasted, what was heard and the app name."
        )
    }
}

struct PagePrompt<Actions: View>: View {
    let said: String
    let heard: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(said)
                .font(Typeface.said)
                .tracking(Typeface.saidTracking)
                .lineSpacing(Typeface.saidLineSpacing)
                .foregroundStyle(Color.ink)
            Text(heard)
                .font(Typeface.heard)
                .lineSpacing(Typeface.heardLineSpacing)
                .foregroundStyle(Color.ink2)
            if Actions.self != EmptyView.self {
                actions.padding(.top, MeetingWindowMetrics.emptyActionsTop - Space.s8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: WindowMetrics.toolbarHeight + ControlMetrics.innerGap, leading: Space.s36, bottom: Space.s36, trailing: Space.s36))
    }
}

extension PagePrompt where Actions == EmptyView {
    init(said: String, heard: String) {
        self.init(said: said, heard: heard) { EmptyView() }
    }
}
