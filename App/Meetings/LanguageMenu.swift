import NarrariKit
import SwiftUI

// The meeting's language on the meta line, a pop-up built like the speaker chip: Detect, then each language the speech model
// transcribes. Choosing one writes the summary and a made title again in it.
struct LanguageMenu: View {
    let line: String
    // The code chosen, empty for Detect.
    let chosen: String
    let onChoose: (String) -> Void

    @State private var anchor = Anchor()
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: open) {
            Text(line)
                .foregroundStyle(isHovered && isEnabled ? Color.ink : Color.muted)
                .padding(.horizontal, MeetingWindowMetrics.chipPadding)
                .padding(.vertical, Space.s2)
                .background(isHovered && isEnabled ? Color.selectionFill : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -MeetingWindowMetrics.chipPadding)
        .padding(.vertical, -Space.s2)
        .onHover { isHovered = $0 }
        .background(AnchorView(anchor: anchor))
        .accessibilityLabel("Language, \(line)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Chooses the language the summary is written in, and writes it again")
    }

    private func open() {
        guard let view = anchor.view else { return }
        let codes = [""] + ParakeetTranscriber.languages.map(\.id)
        let rows = [DropdownRow(title: "Detect")] + ParakeetTranscriber.languages.enumerated().map { index, language in
            DropdownRow(title: language.name, startsSection: index == 0)
        }
        Dropdown.shared.open(label: "Language", rows: rows, chosen: codes.firstIndex(of: chosen), from: view) { index in
            onChoose(codes[index])
        }
    }
}
