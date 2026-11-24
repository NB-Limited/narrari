import NarrariKit
import SwiftUI

struct MenuPanelView: View {
    let context: MenuContext
    // Liquid Glass draws its own rim; the older material needs the panel's edges drawn.
    let isGlass: Bool
    let onSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

    var body: some View {
        let model = context.model
        let dictation = model.dictation
        let shape = RoundedRectangle(cornerRadius: MenuPanelMetrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            MenuStatusSection(context: context)
                .accessibilitySortPriority(1)
            if !model.notes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.notes) { MenuNoteRow(note: $0, context: context) }
                }
                .padding(MenuPanelMetrics.fixRowPadding)
            }
            if let last = model.lastDictation {
                LastDictationCard(last: last, context: context)
            } else {
                EmptyDictationCard(hotkey: model.hotkey)
            }
            MenuModeSection(context: context)
            MenuMicrophoneSection(context: context)
            MenuSeparator()
            MenuRow(item: .dictation, title: dictation.title, isEnabled: dictation.isEnabled, reason: dictation.reason, context: context)
            if let pause = model.meetingPauseTitle {
                MenuRow(item: .meetingPause, title: pause, context: context)
            }
            MenuRow(item: .meeting, title: model.meetingTitle, context: context)
            MenuRow(item: .openMain, title: "Open Narrari", context: context)
            MenuRow(item: .transcribeFile, title: "Transcribe File…", context: context)
            MenuRow(item: .importRecording, title: "Import Recording…", context: context)
            MenuRow(item: .settings, title: "Settings…", context: context)
            MenuSeparator()
            MenuRow(item: .permissions, title: "Permissions…", context: context)
            MenuRow(item: .about, title: "About Narrari", context: context)
            MenuRow(item: .quit, title: "Quit Narrari", context: context)
        }
        .padding(MenuPanelMetrics.inset)
        .frame(width: MenuPanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if reducesTransparency { shape.fill(Color.panelGround) }
        }
        .overlay {
            if !isGlass {
                ZStack {
                    shape.strokeBorder(Color.panelEdge, lineWidth: ControlMetrics.hairline)
                    shape.inset(by: ControlMetrics.hairline).strokeBorder(Color.panelInnerEdge, lineWidth: ControlMetrics.hairline)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .onHover { isInside in
            if !isInside { model.highlight(nil) }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Narrari")
    }
}
