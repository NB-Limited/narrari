import NarrariKit
import SwiftUI

struct AppModesSection: View {
    @Bindable var model: ModesPageModel
    @State private var isPicking = false

    var body: some View {
        FormGroup(label: "Apps") {
            Button("Add app") { isPicking = true }
                .buttonStyle(.secondary)
                .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                    AppPicker(model: model) { bundleIdentifier in
                        model.addApp(bundleIdentifier)
                        isPicking = false
                    }
                }
        } content: {
            if model.appIDs.isEmpty {
                QuietLine(text: "None yet.").padding(.top, -ControlMetrics.errorGap)
            } else {
                Text("Hotkey order. Drag, or ⌥↑ and ⌥↓.")
                    .font(Typeface.small)
                    .foregroundStyle(Color.muted)
                    .padding(.bottom, Space.s8)
                SettingsRows {
                    ForEach(model.appIDs, id: \.self) { app in
                        AppModesRows(model: model, app: app)
                            .padding(.top, app == model.appIDs.first ? 0 : SettingsGrid.blockGap)
                    }
                }
            }
        }
    }
}

// An app's rows in the shared list: the app, its modes in hotkey order, its default, and a way to add one.
private struct AppModesRows: View {
    @Bindable var model: ModesPageModel
    let app: String

    var body: some View {
        let info = model.apps.app(for: app)
        let entry = model.book.apps[app] ?? AppModes(modeIDs: [], defaultID: "")
        let modes = model.book.modes(for: app)
        let others = model.book.modes.filter { !entry.modeIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            RowBlock {
                HStack(spacing: SettingsGrid.controlGap) {
                    if let icon = info.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: ControlMetrics.appIcon, height: ControlMetrics.appIcon)
                            .accessibilityHidden(true)
                    }
                    Text(info.name).font(Typeface.bodyStrong).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: SettingsGrid.rowGap)
                    Button { model.removeApp(app) } label: { Image(systemName: "trash") }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Remove \(info.name)")
                        .iconLabel("Remove \(info.name)")
                        .meetsEdge()
                }
                .frame(minHeight: ControlMetrics.fieldHeight)
            }
            ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                AppModeRow(model: model, app: app, mode: mode, index: index, count: modes.count, isDefault: mode.id == entry.defaultID)
            }
            SettingsRow(title: "Default in \(info.name)", indent: SettingsGrid.appIndent, padding: SettingsGrid.subRowPadding) {
                Popup(
                    label: "Default mode in \(info.name)",
                    selection: Binding(get: { entry.defaultID }, set: { model.setDefault($0, for: app) }),
                    options: modes.map { ($0.id, $0.name) }
                )
            }
            if !others.isEmpty {
                SettingsRow(title: "Add a mode", indent: SettingsGrid.appIndent, padding: SettingsGrid.subRowPadding) {
                    Popup(
                        label: "Add a mode to \(info.name)",
                        selection: Binding(get: { "" }, set: { if !$0.isEmpty { model.addMode($0, to: app) } }),
                        options: [("", "Choose…")] + others.map { ($0.id, $0.name) }
                    )
                }
            }
        }
    }
}

private struct AppModeRow: View {
    let model: ModesPageModel
    let app: String
    let mode: Mode
    let index: Int
    let count: Int
    let isDefault: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        RowBlock(top: SettingsGrid.subRowPadding, bottom: SettingsGrid.subRowPadding, indent: SettingsGrid.appIndent) {
            HStack(spacing: SettingsGrid.modelGap) {
                Text("\(index + 1)")
                    .font(Typeface.small.monospacedDigit())
                    .foregroundStyle(Color.muted)
                    .frame(width: SettingsGrid.orderColumn, alignment: .leading)
                Text(mode.name).font(Typeface.body).foregroundStyle(Color.ink)
                if isDefault {
                    Tag(text: "Default")
                }
                Spacer(minLength: SettingsGrid.rowGap)
                Button { model.removeMode(mode.id, from: app) } label: { Image(systemName: "trash") }
                    .buttonStyle(.icon)
                    .disabled(count < 2)
                    .accessibilityLabel("Remove \(mode.name) from this app")
                    .iconLabel(count < 2 ? "An app keeps at least one mode. Remove the app instead." : "Remove \(mode.name) from this app")
                    .meetsEdge()
            }
            .frame(minHeight: ControlMetrics.fieldHeight)
            .contentShape(Rectangle())
            .focusable()
            .focused($isFocused)
            .focusRing(isFocused, radius: Radius.listItem)
        }
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            move(by: press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .draggable(mode.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.moveMode(id, in: app, to: index)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.name), \(index + 1) of \(count)\(isDefault ? ", default" : "")")
        .accessibilityAction(named: "Move up") { move(by: -1) }
        .accessibilityAction(named: "Move down") { move(by: 1) }
    }

    private func move(by offset: Int) {
        model.moveMode(mode.id, in: app, to: index + offset)
        AccessibilityNotification.Announcement("\(mode.name) moved to \(min(max(index + offset, 0), count - 1) + 1) of \(count)").post()
    }
}

struct AppPicker: View {
    let model: ModesPageModel
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var choices: [AppDirectory.Listing]?

    var body: some View {
        let matches = (choices ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: Space.s8) {
            TextInput(label: "Find an app", text: $query, placeholder: "Find an app", leadingSymbol: "magnifyingglass") {
                if let first = matches.first { onPick(first.bundleIdentifier) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { app in
                        Button { onPick(app.bundleIdentifier) } label: {
                            HStack(spacing: Space.s8) {
                                AppIcon(listing: app, apps: model.apps)
                                Text(app.name).lineLimit(1)
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityLabel(app.name)
                    }
                    if choices != nil, matches.isEmpty {
                        QuietLine(text: "No app matches.").padding(.horizontal, Space.s8)
                    }
                }
            }
        }
        .padding(Space.s12)
        .frame(width: ListMetrics.pickerSize.width, height: ListMetrics.pickerSize.height)
        .background(Color.surface)
        .task { choices = await model.appChoices() }
    }
}

// Loaded when the row first shows, so opening the picker never reads every icon.
private struct AppIcon: View {
    let listing: AppDirectory.Listing
    let apps: AppDirectory
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: ControlMetrics.appIcon, height: ControlMetrics.appIcon)
        .accessibilityHidden(true)
        .task { image = apps.icon(for: listing) }
    }
}
