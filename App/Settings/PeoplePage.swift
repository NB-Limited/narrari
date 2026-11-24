import NarrariKit
import SwiftUI

struct PeoplePage: View {
    @Bindable var model: PeoplePageModel

    var body: some View {
        SettingsPage(title: "People", subtitle: "Voices Narrari knows from your meetings.") {
            FormGroup(label: "Voices") {
                SettingsRows {
                    SwitchRow(title: "Remember voices", isOn: $model.usesVoiceMemory)
                }
            }
            FormGroup(label: "People") {
                SettingsRows {
                    if model.people.isEmpty {
                        QuietLine(text: "No people yet.")
                    }
                    ForEach(model.people) { person in
                        PersonRow(person: person, model: model)
                    }
                }
            }
        }
        .task { await model.appear() }
    }
}

// A person voice memory knows: renamed in place, or forgotten after asking.
private struct PersonRow: View {
    let person: VoiceMemory.Person
    let model: PeoplePageModel

    @State private var name = ""

    var body: some View {
        if model.pendingForget == person.id {
            RowBlock {
                InlineConfirm(
                    message: "Forget \(person.name)? Past meetings keep the name.", action: "Forget",
                    onCancel: { model.pendingForget = nil }, onConfirm: { Task { await model.forget(person.id) } }
                )
            }
        } else if model.editing == person.id {
            RowBlock(bottom: SettingsGrid.editorBottom) {
                FieldLabel(text: "Name", isFirst: true)
                TextInput(label: "Name", text: $name, onSubmit: commit)
                EditorActions(onDone: commit, onCancel: { model.editing = nil })
                    .takesEscape()
            }
            .onAppear { name = person.name }
        } else {
            SettingsRow(title: person.name, isStrong: true) {
                Button { model.pendingForget = person.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.icon)
                    .accessibilityLabel("Forget \(person.name)")
                    .iconLabel("Forget \(person.name)")
                Button { model.editing = person.id } label: { Image(systemName: "pencil") }
                    .buttonStyle(.icon)
                    .accessibilityLabel("Rename \(person.name)")
                    .iconLabel("Rename \(person.name)")
                    .meetsEdge()
            }
        }
    }

    private func commit() {
        Task { await model.rename(person.id, to: name) }
    }
}
