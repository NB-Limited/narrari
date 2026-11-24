import SwiftUI

// A list item whose whole row opens it in place, showing its full text under the name, ready to read and select.
struct OpeningRow<Actions: View>: View {
    let name: String
    let detail: String
    let text: String
    var tag: String?
    @Binding var isOpen: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: SettingsGrid.modelGap) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: Symbol.note, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: SettingsGrid.modelLead, height: SettingsGrid.nameLine, alignment: .leading)
                    .accessibilityElement()
                    .accessibilityLabel(isOpen ? "Hide \(name)" : "Show \(name)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { isOpen.toggle() }
                RowLabel(title: name, detail: detail, isStrong: true, tag: tag)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: SettingsGrid.helperGap) { actions }
                    .frame(height: SettingsGrid.nameLine)
            }
            .frame(minHeight: SettingsGrid.rowMinHeight - 2 * SettingsGrid.rowPadding, alignment: .top)
            .padding(.vertical, SettingsGrid.rowPadding)
            .rowAction { isOpen.toggle() }
            if isOpen {
                Text(text)
                    .font(Typeface.body)
                    .lineSpacing(Typeface.bodyLineSpacing)
                    .foregroundStyle(Color.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SettingsGrid.promptTextPadding)
                    .background(Color.windowGround, in: RoundedRectangle(cornerRadius: Radius.control))
                    .padding(.leading, SettingsGrid.editorIndent)
                    .padding(.bottom, SettingsGrid.editorBottom)
            }
        }
    }
}
