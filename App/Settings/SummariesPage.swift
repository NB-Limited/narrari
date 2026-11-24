import AppKit
import NarrariKit
import SwiftUI

// Built like the Prompts page; the templates are read again whenever Narrari comes to the front.
struct SummariesPage: View {
    @Bindable var model: SummariesPageModel

    var body: some View {
        SettingsPage(title: "Summaries", subtitle: "What a meeting's summary covers.") {
            if let error = model.error {
                FormError(message: error).padding(.top, Space.s12)
            }
            BuiltInListGroups(
                model: model, noun: "template", deleteQuestion: { "Delete \($0)? Summaries already written stay." },
                tag: { $0.id == model.defaultID ? "Default" : nil },
                lead: { template in
                    if template.id != model.defaultID {
                        Button { model.makeDefault(template.id) } label: { Image(systemName: "checkmark.circle") }
                            .buttonStyle(.icon)
                            .accessibilityLabel("Make \(template.name) the default")
                            .iconLabel("Make \(template.name) the default")
                    }
                },
                editor: { TemplateEditor(model: model) }
            )
            FormGroup(label: "Model") {
                SettingsRows {
                    SummaryModelRow(model: model)
                }
            }
        }
        .onAppear(perform: model.appear)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.appear()
        }
    }
}

private struct TemplateEditor: View {
    @Bindable var model: SummariesPageModel

    var body: some View {
        if let draft = Binding.unwrapping($model.draft) {
            ListItemEditor(
                noun: "template", name: draft.name, nameError: model.nameError, textLabel: "Headings", text: draft.text,
                textError: model.textError, onDone: model.commit, onCancel: model.cancelEditing
            ) {
                QuietLine(text: "A line starting with # is a heading; what to write goes under it.")
            }
        }
    }
}
