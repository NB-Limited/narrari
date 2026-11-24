import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Typeface.title)
                    .lineSpacing(Typeface.titleLineSpacing)
                    .foregroundStyle(Color.ink)
                    .padding(.top, SettingsGrid.titleTop)
                    .padding(.bottom, SettingsGrid.titleBottom)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Typeface.small)
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: SettingsGrid.formWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.s36)
            .padding(.bottom, Space.s36)
        }
        .scrollIndicators(.automatic)
    }
}

// Every group head is the same height, so a group with a button in its head sits where one without does.
struct FormGroup<Trailing: View, Content: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(Typeface.label)
                    .tracking(Typeface.groupTracking)
                    .foregroundStyle(Color.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s8)
                trailing
            }
            .frame(height: SettingsGrid.groupHeight)
            .padding(.top, SettingsGrid.groupTop)
            .padding(.bottom, SettingsGrid.groupBottom)
            content
        }
    }
}

extension FormGroup where Trailing == EmptyView {
    init(label: String, @ViewBuilder content: () -> Content) {
        self.init(label: label, trailing: { EmptyView() }, content: content)
    }
}

// Rows in a group are set apart by their padding and alignment, never by a line.
struct SettingsRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
    }
}

// One row of the grid: the label and its line on the left, the main control on the right edge, helpers to its left.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var isStrong = false
    var indent: CGFloat = 0
    var padding = SettingsGrid.rowPadding
    @ViewBuilder var control: Control

    var body: some View {
        RowBlock(top: padding, bottom: padding, indent: indent) {
            RowLine(title: title, detail: detail, isStrong: isStrong) { control }
        }
    }
}

// The row's content without its padding, for a block that adds lines under it.
struct RowLine<Control: View>: View {
    let title: String
    var aside: String?
    var detail: String?
    var isStrong = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: SettingsGrid.rowGap) {
            RowLabel(title: title, aside: aside, detail: detail, isStrong: isStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: SettingsGrid.controlGap) { control }
        }
        .frame(minHeight: ControlMetrics.fieldHeight)
    }
}

struct RowLabel: View {
    let title: String
    // A quiet second name after the title, such as a model's technical name.
    var aside: String?
    var detail: String?
    var isStrong = false
    var tag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsGrid.detailGap) {
            HStack(spacing: SettingsGrid.tagGap) {
                Text(title)
                    .font(isStrong ? Typeface.bodyStrong : Typeface.body)
                    .foregroundStyle(Color.ink)
                    .frame(minHeight: SettingsGrid.nameLine)
                if let aside {
                    Text(aside).font(Typeface.body).foregroundStyle(Color.muted)
                }
                if let tag { Tag(text: tag) }
            }
            if let detail {
                Text(detail)
                    .font(Typeface.small)
                    .foregroundStyle(Color.muted)
                    .frame(minHeight: SettingsGrid.detailLine)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// Anything that takes a row's place in a list: row padding above and below.
struct RowBlock<Content: View>: View {
    var top = SettingsGrid.rowPadding
    var bottom = SettingsGrid.rowPadding
    var indent: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, minHeight: SettingsGrid.rowMinHeight - 2 * SettingsGrid.rowPadding, alignment: .leading)
            .padding(.leading, indent)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }
}

struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            SwitchControl(title: title, isOn: $isOn)
        }
    }
}

struct SwitchControl: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.narrariSwitch)
            .accessibilityLabel(title)
    }
}

// A field across the column with its button on the field line at the right edge.
struct AddLine<Fields: View>: View {
    let label: String
    let isDisabled: Bool
    let onAdd: () -> Void
    @ViewBuilder var fields: Fields

    var body: some View {
        HStack(alignment: .top, spacing: SettingsGrid.controlGap) {
            fields
            Button("Add", action: onAdd)
                .buttonStyle(.secondary)
                .disabled(isDisabled)
                .padding(.top, (ControlMetrics.fieldHeight - ControlMetrics.buttonHeight) / 2)
                .accessibilityLabel(label)
        }
    }
}

struct FieldLabel: View {
    let text: String
    var isFirst = false

    var body: some View {
        Text(text)
            .font(Typeface.small)
            .foregroundStyle(Color.ink2)
            .padding(.top, isFirst ? SettingsGrid.firstFieldTop : Space.s10)
            .padding(.bottom, Space.s4)
            .accessibilityHidden(true)
    }
}

struct FieldPair<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Space.s12) {
            VStack(alignment: .leading, spacing: 0) { leading }
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { trailing }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Done and Cancel under an editor.
struct EditorActions: View {
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Space.s8) {
            Button("Done", action: onDone).buttonStyle(.primary)
            Button("Cancel", action: onCancel)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, Space.s12)
    }
}

// One quiet line under what it is about: 12 pt Muted, 5 pt below it.
struct QuietLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.small)
            .foregroundStyle(Color.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, ControlMetrics.errorGap)
    }
}

extension View {
    // An icon button at a column's edge is pulled out so its symbol, not its hit area, meets the edge.
    func meetsEdge(_ edge: Edge.Set = .trailing) -> some View {
        padding(edge, -SettingsGrid.edgeIconPull)
    }
}
