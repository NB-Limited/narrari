import NarrariKit
import SwiftUI

// The microphone the next dictation records from; with one connected it is plain text.
struct MenuMicrophoneSection: View {
    let context: MenuContext

    var body: some View {
        let model = context.model
        MenuChoiceRow(
            item: .microphone, title: "Microphone", value: model.microphoneValue, isChoice: model.hasMicrophoneChoice,
            isOpen: model.isMicrophoneListOpen, listName: "microphones", context: context
        ) {
            ForEach(model.microphoneOptions) { option in
                MenuChoiceOption(
                    item: .microphoneOption(option.id), title: option.title, isCurrent: option.isChosen,
                    tag: option.isInUse ? "In use" : nil, context: context
                )
            }
        }
    }
}
