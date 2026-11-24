import SwiftUI

struct SettingsSidebar: View {
    let selection: SettingsSection
    // The side of the switch the back row returns to.
    let back: String
    let isPermissionMissing: Bool
    // Nil goes back to the dictations.
    let onSelect: (SettingsSection?) -> Void
    let onAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onSelect(nil) } label: {
                Label(back, systemImage: "chevron.left")
                    .labelStyle(NavLabelStyle(symbolColor: .ink2))
                    .foregroundStyle(Color.ink2)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("Back to \(back)")
            .padding(.top, Space.s2)
            .padding(.horizontal, Space.s8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SettingsGroup.allCases) { group in
                        groupHead(group)
                        ForEach(group.sections, id: \.self, content: row)
                    }
                }
                .padding(.horizontal, Space.s8)
            }
            .scrollIndicators(.automatic)
            Button(action: onAbout) {
                Label("About Narrari", systemImage: "info.circle").labelStyle(NavLabelStyle())
            }
            .buttonStyle(RowButtonStyle())
            .padding(Space.s8)
        }
    }

    private func groupHead(_ group: SettingsGroup) -> some View {
        Text(group.title)
            .font(Typeface.label)
            .tracking(Typeface.groupTracking)
            .foregroundStyle(Color.muted)
            .padding(EdgeInsets(top: Space.s10, leading: Space.s8, bottom: Space.s2, trailing: Space.s8))
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ section: SettingsSection) -> some View {
        Button { onSelect(section) } label: {
            HStack(spacing: Space.s8) {
                Label(section.title, systemImage: section.symbol).labelStyle(NavLabelStyle())
                if section == .permissions, isPermissionMissing {
                    Spacer(minLength: Space.s8)
                    PermissionWarning()
                }
            }
        }
        .buttonStyle(RowButtonStyle(isSelected: section == selection))
    }
}
