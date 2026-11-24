import NarrariKit
import SwiftUI

struct HistoryPage: View {
    let model: HistoryPageModel

    var body: some View {
        SettingsPage(title: "History", subtitle: "Dictations and meetings, readable only by you.") {
            if let error = model.error {
                FormError(message: error).padding(.top, Space.s12)
            }
            FormGroup(label: "Keep") {
                SettingsRows {
                    keepRow("Keep dictations", .dictations)
                    keepRow("Keep meeting audio", .meetingAudio)
                }
            }
            FormGroup(label: "Stored on this Mac") {
                SettingsRows {
                    SettingsRow(title: model.usageLine, detail: model.locationLine) {
                        Button("Show in Finder", action: model.showInFinder)
                            .buttonStyle(.secondary)
                            .accessibilityLabel("Show dictations in Finder")
                    }
                    SettingsRow(title: model.meetingUsageLine, detail: model.meetingLocationLine) {
                        Button("Show in Finder", action: model.showMeetingsInFinder)
                            .buttonStyle(.secondary)
                            .accessibilityLabel("Show meetings in Finder")
                    }
                }
            }
            FormGroup(label: "Delete") {
                SettingsRows {
                    if let message = model.deleteAllMessage {
                        RowBlock {
                            InlineConfirm(
                                message: message,
                                action: "Delete all",
                                onCancel: model.cancelDeleteAll,
                                onConfirm: { Task { await model.confirmDeleteAll() } }
                            )
                        }
                    } else {
                        SettingsRow(title: "Delete all dictations", detail: "Every dictation and its audio.") {
                            Button("Delete all…", action: model.requestDeleteAll)
                                .buttonStyle(.destructive)
                                .disabled((model.usage?.dictations ?? 0) == 0)
                        }
                    }
                }
            }
        }
        .task { await model.appear() }
    }

    // A shorter time asks first under its row, because it deletes what is older at once.
    private func keepRow(_ title: String, _ kind: HistoryPageModel.Kind) -> some View {
        RowBlock {
            RowLine(title: title, detail: model.retentionDetail(kind)) {
                Popup(
                    label: title,
                    selection: Binding(get: { model.days(kind) }, set: { requestRetention($0, for: kind) }),
                    options: model.retentionOptions(kind).map { ($0, HistoryPageModel.title(forDays: $0)) }
                )
            }
            if let message = model.pendingRetentionMessage(kind) {
                InlineConfirm(
                    message: message,
                    onCancel: model.cancelRetention,
                    onConfirm: { Task { await model.confirmRetention() } }
                )
                .padding(.top, SettingsGrid.rowPadding)
            }
        }
    }

    private func requestRetention(_ days: Int, for kind: HistoryPageModel.Kind) {
        Task { await model.requestRetention(days, for: kind) }
    }
}
