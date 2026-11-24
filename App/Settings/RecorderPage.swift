import NarrariKit
import SwiftUI

struct RecorderPage: View {
    @Bindable var model: RecorderPageModel

    var body: some View {
        SettingsPage(title: "Recorder", subtitle: "What you hear and see while you dictate.") {
            FormGroup(label: "Sound") {
                SettingsRows {
                    SwitchRow(title: "Start and stop sounds", isOn: $model.playsSounds)
                    SettingsRow(title: "Sound") {
                        SoundPlayButton(set: model.soundSet, isPlaying: model.playingSound == model.soundSet) { model.previewSound(model.soundSet) }
                        SoundPicker(model: model)
                    }
                    .disabled(!model.playsSounds)
                    SwitchRow(title: "Mute other sound", detail: model.muteDetail, isOn: $model.mutesOutput)
                }
            }
            FormGroup(label: "Look") {
                SettingsRows {
                    SwitchRow(title: "Show live text", detail: "In the recorder at the bottom.", isOn: $model.showsLiveText)
                    RowBlock {
                        RowLine(title: "Recorder look") {
                            Popup(label: "Recorder look", selection: $model.pillLook, options: PillLook.allCases.map { ($0, $0.name) })
                        }
                        if model.pillLook.isColoured {
                            RowLine(title: "Colour") {
                                SwatchRow(label: "Colour", selection: $model.pillColour)
                            }
                            .padding(.top, Space.s8)
                        }
                        RecorderPreview(look: model.pillLook, colour: model.pillColour, showsWords: model.showsLiveText)
                            .padding(.top, PillPreviewMetrics.top)
                    }
                }
            }
        }
        .onAppear(perform: model.appear)
    }
}
