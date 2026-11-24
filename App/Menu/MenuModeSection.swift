import NarrariKit
import SwiftUI

// The mode for the app in front.
struct MenuModeSection: View {
    let context: MenuContext

    var body: some View {
        let model = context.model
        let choice = model.modeChoice
        MenuChoiceRow(
            item: .mode, title: model.modeTitle, value: choice.current.name, isChoice: model.hasModeChoice,
            isOpen: model.isModeListOpen, listName: "modes", context: context
        ) {
            ForEach(choice.modes) { mode in
                MenuChoiceOption(item: .modeOption(mode.id), title: mode.name, isCurrent: mode.id == choice.current.id, context: context)
            }
        }
        .padding(.top, MenuPanelMetrics.modeTop)
    }
}
