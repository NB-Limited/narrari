import NarrariKit
import SwiftUI

struct PromptsPage: View {
    @Bindable var model: PromptsPageModel

    var body: some View {
        SettingsPage(title: "Prompts", subtitle: "What clean-up does with your words.") {
            FileNotice(file: model.file, storeError: model.storeError, onStartFresh: model.startFresh)
            BuiltInListGroups(
                model: model, noun: "prompt", deleteQuestion: { "Delete \($0)? Modes that use it switch to Tidy." },
                editor: { PromptEditor(model: model) }
            )
            .disabled(model.file.isUnreadable)
        }
        .onAppear(perform: model.appear)
    }
}

private struct PromptEditor: View {
    @Bindable var model: PromptsPageModel

    var body: some View {
        if let draft = Binding.unwrapping($model.draft) {
            ListItemEditor(
                noun: "prompt", name: draft.name, nameError: model.nameError, textLabel: "Instruction", text: draft.instruction,
                textError: model.instructionError, onDone: model.commit, onCancel: model.cancelEditing
            ) {
                FieldLabel(text: "Trigger phrases")
                TextInput(label: "Trigger phrases", text: draft.triggers, placeholder: "write email, draft email", error: model.triggerError)
                QuietLine(text: "Separate with commas. Optional.")
            }
        }
    }
}
