import NarrariKit
import SwiftUI

struct SpeechPage: View {
    @Bindable var model: SpeechPageModel
    let meetingModels: MeetingModels

    var body: some View {
        SettingsPage(title: "Speech", subtitle: "Turns your voice into text.") {
            FormGroup(label: "Model") {
                ModelSidePicker(side: $model.side, inUse: model.sideInUse)
                if model.side == .thisMac {
                    localModels
                } else {
                    SettingsRows {
                        OutsideServiceRowView(
                            row: model.serviceRow, isEditing: model.isEditingService, onChoose: {}, onSetUp: model.beginServiceSetup,
                            editor: { ServiceEditor(model: model) }
                        )
                    }
                    .padding(.top, SettingsGrid.listTop)
                    if model.serviceRow.status == .ready {
                        QuietLine(text: "Modes choose when to use it.")
                    }
                }
            }

            FormGroup(label: "For meetings") {
                SettingsRows {
                    ForEach(MeetingModels.all, id: \.self) { audioModel in
                        MeetingModelRow(model: audioModel, models: meetingModels)
                    }
                }
            }

            FormGroup(label: "Microphone") {
                SettingsRows {
                    SettingsRow(title: "Microphone", detail: model.microphoneDetail) {
                        Popup(label: "Microphone", selection: $model.microphoneUID, options: model.microphoneOptions)
                    }
                    SwitchRow(title: "Use the built-in microphone instead of Bluetooth", isOn: $model.prefersBuiltInOverBluetooth)
                        .disabled(model.isMicrophoneChosen)
                }
            }
        }
        .onAppear {
            model.appear()
            meetingModels.refresh()
        }
        .onDisappear(perform: model.disappear)
        .onChange(of: model.models.state) { model.models.refreshSize() }
    }

    @ViewBuilder private var localModels: some View {
        ModelList(model: model, job: .speech, blockedReason: model.isChangeBlocked ? SpeechPageModel.busyReason : nil)
        if model.showsNeedsModel {
            FormError(message: SpeechPageModel.needsModel).padding(.top, ControlMetrics.errorGap)
        }
        if let error = model.changeError {
            FormError(message: error).padding(.top, ControlMetrics.errorGap)
        } else if model.isChangeBlocked {
            QuietLine(text: SpeechPageModel.busyReason)
        }
    }
}

private struct ServiceEditor: View {
    @Bindable var model: SpeechPageModel

    var body: some View {
        FieldLabel(text: "Address", isFirst: true)
        TextInput(label: "Address", text: $model.remoteAddress, placeholder: "https://", error: model.addressError)
        FieldPair {
            FieldLabel(text: "Model")
            TextInput(label: "Model", text: $model.remoteModel, error: model.modelError)
        } trailing: {
            FieldLabel(text: "Language")
            TextInput(label: "Language", text: $model.remoteLanguage, placeholder: "Detect", error: model.languageError)
        }
        KeyField(label: "Speech service key", key: model.key)
        EditorActions(onDone: model.finishServiceSetup, onCancel: model.cancelServiceSetup)
            .takesEscape()
    }
}

// A model a meeting needs besides speech: what it does, its size, and Download, Cancel or the trash.
private struct MeetingModelRow: View {
    let model: AudioModel
    let models: MeetingModels

    @State private var isDeleting = false

    var body: some View {
        let status = models.status(of: model)
        let name = MeetingModels.plainName(of: model)
        if isDeleting, case .onThisMac(let bytes) = status {
            RowBlock {
                InlineConfirm(
                    message: "Delete \(name) from this Mac? This frees \(MetricText.bytes(bytes)).",
                    onCancel: { isDeleting = false },
                    onConfirm: {
                        isDeleting = false
                        models.delete(model)
                    }
                )
            }
        } else {
            RowBlock {
                RowLine(title: name, aside: model.name, detail: models.detail(of: model), isStrong: true) {
                    switch status {
                    case .notDownloaded:
                        Button("Download") { models.begin([model]) }
                            .buttonStyle(.secondary)
                            .accessibilityLabel("Download \(name)")
                    case .work(.failed):
                        Button("Try again") { models.begin([model]) }.buttonStyle(.secondary)
                    case .work:
                        Button("Cancel") { models.cancel(model) }.buttonStyle(.secondary)
                    case .onThisMac:
                        Button { isDeleting = true } label: { Image(systemName: "trash") }
                            .buttonStyle(.icon)
                            .accessibilityLabel("Delete \(name)")
                            .iconLabel("Delete \(name)")
                            .meetsEdge()
                    }
                }
                if let problem = status.work.problem {
                    FormError(message: problem.besideRetry).padding(.top, ControlMetrics.errorGap)
                } else if let fraction = status.work.progress {
                    ProgressBar(fraction: fraction, label: "Downloading \(name)", track: .meterTrack)
                        .padding(.top, SettingsGrid.progressTop)
                }
            }
        }
    }
}
