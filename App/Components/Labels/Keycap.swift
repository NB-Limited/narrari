import SwiftUI

// The hotkey as a key: the menu panel's status row and the dictation key legend in General.
struct Keycap: View {
    let key: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MenuPanelMetrics.keycapRadius, style: .continuous)
        Text(key)
            .font(Typeface.labelMedium)
            .foregroundStyle(Color.keycapText)
            .lineLimit(1)
            .padding(.horizontal, MenuPanelMetrics.keycapPadding)
            .frame(height: MenuPanelMetrics.keycapHeight)
            .background {
                shape
                    .fill(Color.keycap)
                    .shadow(color: .keycapShadow, radius: 0, y: MenuPanelMetrics.keycapDrop)
            }
            .overlay {
                RoundedRectangle(cornerRadius: MenuPanelMetrics.keycapRadius + ControlMetrics.hairline / 2, style: .continuous)
                    .stroke(Color.keycapEdge, lineWidth: ControlMetrics.hairline)
                    .padding(-ControlMetrics.hairline / 2)
            }
    }
}
