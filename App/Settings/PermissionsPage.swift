import NarrariKit
import SwiftUI

struct PermissionsPage: View {
    let permissions: Permissions

    var body: some View {
        SettingsPage(title: "Permissions", subtitle: permissions.isComplete ? "Narrari has what it needs." : "Needed before the first dictation.") {
            FormGroup(label: "This Mac") {
                SettingsRows {
                    PermissionRow(
                        symbol: "mic.fill",
                        name: "Microphone",
                        reason: "Hears you only while you dictate or record a meeting.",
                        status: permissions.microphone == .allowed
                            ? .allowed : .missing(permissions.microphone == .denied ? "Turned off in System Settings" : "Not allowed yet"),
                        button: permissions.microphone == .notAsked ? "Allow Microphone" : "Open Microphone Settings",
                        isPrimary: true,
                        action: permissions.requestMicrophone
                    )
                    PermissionRow(
                        symbol: "accessibility",
                        name: "Accessibility",
                        reason: "Notices the key, pastes the text, reads names in a call window.",
                        status: permissions.isAccessibilityAllowed ? .allowed : .missing("Not allowed yet"),
                        button: "Open Accessibility Settings",
                        isPrimary: permissions.microphone == .allowed,
                        action: permissions.requestAccessibility
                    )
                }
                if !permissions.isComplete {
                    QuietLine(text: "This page updates by itself.")
                }
            }
            FormGroup(label: "Meetings") {
                SettingsRows {
                    PermissionRow(
                        symbol: "speaker.wave.2",
                        name: "System audio",
                        reason: "Records the other side of a call.",
                        status: systemAudioStatus
                    )
                    PermissionRow(
                        symbol: "calendar",
                        name: "Calendar",
                        reason: "Names meetings and who is in them.",
                        status: permissions.calendar == .allowed
                            ? .allowed : permissions.calendar == .denied ? .missing("Turned off in System Settings") : .waiting("Optional"),
                        button: permissions.calendar == .notAsked ? "Allow Calendar" : "Open Calendar Settings",
                        action: permissions.requestCalendar
                    )
                }
            }
        }
        .onAppear { permissions.refresh(); permissions.watch() }
    }

    // macOS never tells an app whether it may record other apps' sound, so the last recording is the answer.
    private var systemAudioStatus: PermissionRow.Status {
        switch permissions.systemAudio {
        case .allowed: .allowed
        case .notRecorded: .waiting(permissions.systemAudio.status)
        case .silent: .missing(permissions.systemAudio.status)
        }
    }
}

// One primary button on the page: the first permission still missing.
private struct PermissionRow: View {
    enum Status {
        case allowed
        case missing(String)
        case waiting(String)
    }

    let symbol: String
    let name: String
    let reason: String
    let status: Status
    var button: String?
    var isPrimary = false
    var action: () -> Void = {}

    var body: some View {
        RowBlock {
            HStack(alignment: .center, spacing: SettingsGrid.modelGap) {
                Image(systemName: symbol)
                    .font(.system(size: Symbol.permission))
                    .foregroundStyle(Color.ink)
                    .frame(width: SettingsGrid.modelLead, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, SettingsGrid.summaryTop)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    RowLabel(title: name, detail: reason, isStrong: true)
                    switch status {
                    case .allowed:
                        EmptyView()
                    case .missing(let text):
                        Label(text, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(TightLabelStyle())
                            .font(Typeface.smallMedium)
                            .foregroundStyle(Color.errorInk)
                            .padding(.top, ControlMetrics.errorGap)
                    case .waiting(let text):
                        Text(text)
                            .font(Typeface.smallMedium)
                            .foregroundStyle(Color.ink2)
                            .padding(.top, ControlMetrics.errorGap)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if case .allowed = status {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .labelStyle(TightLabelStyle())
                        .font(Typeface.smallMedium)
                        .foregroundStyle(Color.ink2)
                        .frame(minWidth: SettingsGrid.actionWidth, alignment: .trailing)
                } else if let button {
                    Button(button, action: action)
                        .buttonStyle(isPrimary ? .primary : .secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}
