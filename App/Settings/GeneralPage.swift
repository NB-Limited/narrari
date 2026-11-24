import NarrariKit
import SwiftUI

struct GeneralPage: View {
    @Bindable var model: GeneralPageModel

    var body: some View {
        SettingsPage(title: "General", subtitle: "How Narrari starts and moves.") {
            FormGroup(label: "Start") {
                SettingsRows {
                    RowBlock {
                        RowLine(title: "Open at login", detail: model.launchDetail) {
                            if model.launchAtLogin == .needsApproval {
                                Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                                    .buttonStyle(.secondary)
                            }
                            SwitchControl(title: "Open at login", isOn: Binding(
                                get: { model.launchAtLogin != .off },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                        }
                        if let error = model.launchError {
                            FormError(message: error).padding(.top, ControlMetrics.errorGap)
                        }
                    }
                }
            }
            FormGroup(label: "Motion") {
                SettingsRows {
                    SwitchRow(title: "Follow Reduce Motion", detail: "The setting in System Settings, Accessibility.", isOn: $model.followsReduceMotion)
                }
            }
        }
        .onAppear(perform: model.appear)
    }
}
