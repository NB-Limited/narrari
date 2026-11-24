import NarrariKit
import SwiftUI

struct CleanupPage: View {
    @Bindable var model: CleanupPageModel

    var body: some View {
        SettingsPage(title: "Clean-up", subtitle: "Fixes punctuation and drops filler words.") {
            FormGroup(label: "Use") {
                SettingsRows {
                    SwitchRow(title: "Clean up every dictation", detail: "A mode can turn it off.", isOn: $model.isEnabled)
                    SwitchRow(title: "Trigger phrases", detail: "A spoken phrase picks a prompt.", isOn: $model.usesTriggers)
                    SkippedLanguagesRow(model: model)
                }
            }

            FormGroup(label: "Model") {
                ModelSidePicker(side: $model.side, inUse: model.sideInUse)
                if model.side == .thisMac {
                    localModels
                } else {
                    SettingsRows {
                        OutsideServiceRowView(
                            row: model.serviceRow, isEditing: model.isEditingService,
                            onChoose: model.chooseService, onSetUp: model.beginServiceSetup
                        ) {
                            ServiceEditor(model: model)
                        }
                    }
                    .padding(.top, SettingsGrid.listTop)
                }
            }
        }
        .onAppear(perform: model.appear)
        .onChange(of: model.engines.localStatus.state) { model.refreshSize() }
    }

    @ViewBuilder private var localModels: some View {
        ModelList(model: model, job: .cleanup)
        if let error = model.deletionError {
            FormError(message: error).padding(.top, ControlMetrics.errorGap)
        }
    }

    static func seconds(_ value: Double) -> (value: Double, title: String) {
        (value, "\(value.formatted()) seconds")
    }
}

private struct ServiceEditor: View {
    @Bindable var model: CleanupPageModel

    var body: some View {
        FieldLabel(text: "Address", isFirst: true)
        TextInput(label: "Address", text: $model.chatAddress, placeholder: "https://", error: model.addressError)
        FieldPair {
            FieldLabel(text: "Model")
            TextInput(label: "Model", text: $model.chatModel, error: model.modelError)
        } trailing: {
            FieldLabel(text: "Answers within")
            Popup(
                label: "Time limit for the outside service",
                selection: $model.chatTimeLimit,
                options: model.chatTimeLimitOptions.map(CleanupPage.seconds),
                isFullWidth: true
            )
        }
        KeyField(label: "Chat service key", key: model.key)
        EditorActions(onDone: model.finishServiceSetup, onCancel: model.cancelServiceSetup)
            .takesEscape()
    }
}

private struct SkippedLanguagesRow: View {
    let model: CleanupPageModel

    var body: some View {
        RowBlock {
            RowLine(title: "Languages to skip") {
                Popup(
                    label: "Add a language to skip",
                    selection: Binding(get: { "" }, set: { if !$0.isEmpty { model.skip($0) } }),
                    options: [("", "Choose…")] + model.languagesToSkip.map { ($0.id, $0.name) }
                )
            }
            ForEach(model.skippedLanguages, id: \.self) { code in
                let name = SpokenLanguage.name(of: code)
                HStack(spacing: SettingsGrid.rowGap) {
                    Text(name)
                        .font(Typeface.body)
                        .foregroundStyle(Color.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.stopSkipping(code) } label: { Image(systemName: "trash") }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Remove \(name)")
                        .iconLabel("Remove \(name)")
                        .meetsEdge()
                }
                .frame(minHeight: ControlMetrics.fieldHeight)
            }
        }
    }
}
