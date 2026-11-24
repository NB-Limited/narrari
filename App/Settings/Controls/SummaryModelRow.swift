import NarrariKit
import SwiftUI

// The model summaries are written with by default; the chat service is offered once it is set up on Clean-up.
struct SummaryModelRow: View {
    @Bindable var model: SummariesPageModel

    var body: some View {
        RowBlock {
            RowLine(title: "Summary model") {
                Popup(label: "Summary model", selection: $model.summaryModel, options: model.summaryOptions.map { ($0.id, $0.name) })
            }
            if !model.isOutsideSetUp {
                QuietLine(text: "To summarise with an outside service, set it up on the Clean-up page.")
            } else if model.summaryModel == SummaryModels.outside {
                LeavesMacTag(text: "Text leaves this Mac")
                    .padding(.top, ControlMetrics.errorGap)
            }
        }
    }
}
