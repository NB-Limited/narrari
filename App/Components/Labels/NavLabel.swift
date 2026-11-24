import SwiftUI

// The triangle on the Settings and Permissions rows while a permission is missing.
struct PermissionWarning: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: SettingsGrid.warning))
            .foregroundStyle(Color.errorInk)
            .accessibilityLabel("A permission is missing")
    }
}

struct NavLabelStyle: LabelStyle {
    var symbolColor = Color.ink

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s8) {
            configuration.icon
                .font(.system(size: Symbol.window))
                .foregroundStyle(symbolColor)
                .frame(width: Symbol.window + Space.s2)
            configuration.title
        }
    }
}

// A row pinned at the bottom of the sidebar: symbol, name, and its shortcut in Muted at the right.
struct SidebarRow: View {
    let title: String
    let symbol: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s8) {
                Label(title, systemImage: symbol).labelStyle(NavLabelStyle())
                Spacer(minLength: Space.s8)
                Text(shortcut).font(Typeface.small).foregroundStyle(Color.muted)
            }
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(title)
    }
}

// Settings at the bottom of the sidebar; while a permission is missing its warning takes the shortcut's place.
struct SettingsRowButton: View {
    let isPermissionMissing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s8) {
                Label("Settings", systemImage: "gearshape").labelStyle(NavLabelStyle())
                Spacer(minLength: Space.s8)
                if isPermissionMissing {
                    PermissionWarning()
                } else {
                    Text("⌘,").font(Typeface.small).foregroundStyle(Color.muted)
                }
            }
        }
        .buttonStyle(RowButtonStyle())
        .keyboardShortcut(",")
        .accessibilityLabel("Settings")
    }
}
