import AppKit
import NarrariKit
import SwiftUI

struct RecordingPage: View {
    @Bindable var model: RecordingPageModel
    let looks: PillLookModel

    var body: some View {
        SettingsPage(title: "Recording", subtitle: "How calls are recorded.") {
            FormGroup(label: "Calls") {
                SettingsRows {
                    SettingsRow(title: "Start a call's recording") {
                        Popup(
                            label: "Start a call's recording", selection: $model.startsByItself,
                            options: [(false, "When I choose Start"), (true, "By itself")]
                        )
                    }
                    SwitchRow(title: "Stop when the call ends", isOn: $model.stopsWithCall)
                    RowBlock {
                        RowLine(title: "Read names from the call window") {
                            SwitchControl(title: "Read names from the call window", isOn: $model.readsCallWindowNames)
                        }
                        QuietLine(text: "Microsoft Teams may respond more slowly while it is read.")
                    }
                    ignoredApps
                }
            }
            FormGroup(label: "Look") {
                SettingsRows {
                    SwitchRow(title: "Show live text", detail: "On the meeting's page as it records.", isOn: $model.showsLiveText)
                    RowBlock {
                        RowLine(title: "Meeting bar") {
                            Popup(label: "Meeting bar", selection: $model.bar, options: [(.pill, "Recorder pill"), (.chip, "Corner chip"), (.hidden, "Hidden")])
                        }
                        if model.bar == .hidden {
                            QuietLine(text: "Only the menu bar icon marks the recording. A problem with it still shows.")
                        }
                        RecorderPreview(look: looks.look, colour: looks.colour, showsWords: false, meetingBar: model.bar)
                            .padding(.top, PillPreviewMetrics.top)
                    }
                }
            }
        }
        .task { await model.appear() }
    }

    // A popup that adds an app; each app chosen is a line under it with its trash.
    @ViewBuilder private var ignoredApps: some View {
        RowBlock {
            RowLine(title: "Apps to leave alone") {
                Popup(
                    label: "Add an app to leave alone",
                    selection: Binding(get: { "" }, set: { if !$0.isEmpty { model.ignore($0) } }),
                    options: [("", "Choose…")] + model.appChoices.map { ($0.bundleIdentifier, $0.name) }
                )
            }
            ForEach(model.ignoredApps, id: \.self) { bundleIdentifier in
                let app = model.apps.app(for: bundleIdentifier)
                HStack(spacing: Space.s8) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: ControlMetrics.appIcon, height: ControlMetrics.appIcon)
                            .accessibilityHidden(true)
                    }
                    Text(app.name)
                        .font(Typeface.body)
                        .foregroundStyle(Color.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.stopIgnoring(bundleIdentifier) } label: { Image(systemName: "trash") }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Remove \(app.name)")
                        .iconLabel("Remove \(app.name)")
                        .meetsEdge()
                }
                .frame(minHeight: ControlMetrics.fieldHeight)
            }
        }
    }
}
