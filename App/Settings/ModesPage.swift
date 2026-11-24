import NarrariKit
import SwiftUI

struct ModesPage: View {
    @Bindable var model: ModesPageModel

    var body: some View {
        SettingsPage(title: "Modes", subtitle: "Prompt, clean-up and speech, per app.") {
            FileNotice(file: model.file, storeError: model.storeError, onStartFresh: model.startFresh)
            Group {
                FormGroup(label: "Default for every app") {
                    SettingsRows {
                        SettingsRow(title: "Default mode", detail: "For apps without modes of their own.") {
                            Popup(label: "Default mode", selection: $model.globalDefaultID, options: model.book.modes.map { ($0.id, $0.name) })
                        }
                    }
                }
                FormGroup(label: "Modes") {
                    if model.draft == nil {
                        Button("Add mode", action: model.startAdding).buttonStyle(.secondary)
                    }
                } content: {
                    SettingsRows {
                        ForEach(model.book.modes) { mode in
                            row(for: mode)
                        }
                        if let draft = model.draft, draft.isNew {
                            RowBlock(bottom: SettingsGrid.editorBottom) { ModeEditor(model: model) }
                        }
                    }
                }
                AppModesSection(model: model)
            }
            .disabled(model.file.isUnreadable)
        }
        .onAppear(perform: model.appear)
    }

    @ViewBuilder private func row(for mode: Mode) -> some View {
        if let draft = model.draft, draft.id == mode.id {
            RowBlock(bottom: SettingsGrid.editorBottom) { ModeEditor(model: model) }
        } else if model.pendingDeletion == mode.id {
            RowBlock {
                InlineConfirm(
                    message: deletionMessage(for: mode),
                    onCancel: model.cancelDeletion,
                    onConfirm: model.confirmDeletion
                )
            }
        } else {
            RowBlock {
                HStack(alignment: .top, spacing: SettingsGrid.rowGap) {
                    VStack(alignment: .leading, spacing: SettingsGrid.detailGap) {
                        RowLabel(title: mode.name, detail: model.summary(of: mode), isStrong: true)
                        if !model.canDelete(mode.id) {
                            Text(ModesPageModel.globalDefaultReason)
                                .font(Typeface.small)
                                .foregroundStyle(Color.muted)
                                .frame(minHeight: SettingsGrid.detailLine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: SettingsGrid.helperGap) {
                        Button { model.requestDeletion(mode.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.icon)
                            .disabled(!model.canDelete(mode.id))
                            .accessibilityLabel("Delete \(mode.name)")
                            .accessibilityHint(model.canDelete(mode.id) ? "" : ModesPageModel.globalDefaultReason)
                            .iconLabel(model.canDelete(mode.id) ? "Delete \(mode.name)" : ModesPageModel.globalDefaultReason)
                        Button { model.startEditing(mode.id) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.icon)
                            .accessibilityLabel("Edit \(mode.name)")
                            .iconLabel("Edit \(mode.name)")
                            .meetsEdge()
                    }
                    .frame(height: SettingsGrid.nameLine)
                }
            }
        }
    }

    private func deletionMessage(for mode: Mode) -> String {
        switch model.appsUsing(mode.id) {
        case 0: "Delete \(mode.name)?"
        case 1: "Delete \(mode.name)? One app uses it and moves to its next mode."
        case let count: "Delete \(mode.name)? \(count) apps use it and move to their next mode."
        }
    }
}

private struct ModeEditor: View {
    @Bindable var model: ModesPageModel
    @FocusState private var isNameFocused: Bool

    var body: some View {
        if let draft = Binding.unwrapping($model.draft) {
            VStack(alignment: .leading, spacing: 0) {
                FieldLabel(text: "Name", isFirst: true)
                TextInput(label: "Mode name", text: draft.name, error: model.nameError, focus: $isNameFocused, onSubmit: model.commit)
                RowLine(title: "Clean up") {
                    SwitchControl(title: "Clean up", isOn: draft.isCleanupOn)
                }
                .padding(.top, Space.s10)
                FieldLabel(text: "Prompt")
                Popup(label: "Prompt", selection: draft.promptID, options: model.prompts.map { ($0.id, $0.name) }, isFullWidth: true)
                    .disabled(!draft.wrappedValue.isCleanupOn)
                FieldLabel(text: "Speech")
                speechChoice(draft.speech)
                EditorActions(onDone: model.commit, onCancel: model.cancelEditing)
            }
            .onAppear { isNameFocused = true }
            .takesEscape()
        }
    }

    @ViewBuilder private func speechChoice(_ speech: Binding<Mode.Speech>) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            choice("On this Mac", value: .local, speech: speech)
            choice("Outside service", value: .outside, speech: speech)
                .disabled(!model.isOutsideReady && speech.wrappedValue != .outside)
            if !model.isOutsideReady {
                QuietLine(text: ModesPageModel.outsideReason)
            } else if speech.wrappedValue == .outside {
                LeavesMacTag(text: "Audio leaves this Mac")
            }
        }
    }

    private func choice(_ title: String, value: Mode.Speech, speech: Binding<Mode.Speech>) -> some View {
        HStack(spacing: SettingsGrid.modelGap) {
            RadioButton(isOn: speech.wrappedValue == value, label: title) { speech.wrappedValue = value }
            Text(title).font(Typeface.body).foregroundStyle(Color.ink).accessibilityHidden(true)
        }
    }
}
