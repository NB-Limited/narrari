import AppKit
import SwiftUI

@MainActor
final class AboutPanel {
    private var panel: NSPanel?

    func show() {
        let panel = panel ?? makePanel()
        NSApplication.shared.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = "About Narrari"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(named: "Surface")
        panel.contentView = NSHostingView(rootView: AboutView())
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        panel.center()
        self.panel = panel
        return panel
    }
}

struct AboutView: View {
    private static let credits: [(name: String, licence: String)] = [
        ("Parakeet Ultra and v3 speech models", "CC-BY-4.0"),
        ("Parakeet CTC 110M dictionary model", "CC-BY-4.0"),
        ("Qwen3.5 clean-up model", "Apache-2.0"),
        ("Speaker models: pyannote community-1, WeSpeaker and BUT Speech@FIT, converted by Fluid Inference", "CC-BY-4.0"),
        ("LocalVQE echo removal model", "Apache-2.0"),
        ("Silero VAD speech detection model", "MIT"),
        ("FluidAudio", "Apache-2.0"),
        ("mlx-swift and mlx-swift-lm", "MIT"),
        ("swift-transformers and swift-huggingface", "Apache-2.0"),
        ("Source Serif 4", "SIL OFL 1.1")
    ]

    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        VStack(spacing: 0) {
            // Set from the bundled font per the wordmark rule, so it follows the theme like any other text.
            // Tracking also trails the last letter, so the same space leads to keep the word centred.
            Text("NARRARI")
                .font(Typeface.wordmark)
                .tracking(Typeface.wordmarkTracking)
                .padding(.leading, Typeface.wordmarkTracking)
                .foregroundStyle(Color.ink)
                .accessibilityLabel("Narrari")
            HStack(spacing: Space.s4) {
                Text("by")
                Text("NB Limited").fontWeight(.semibold)
            }
            .font(Typeface.small)
            .foregroundStyle(Color.muted)
            .padding(.top, Space.s14)
            .accessibilityElement(children: .combine)

            Text("Version \(version) (\(build))")
                .font(Typeface.small)
                .foregroundStyle(Color.ink2)
                .padding(.top, Space.s20)
            Text("Copyright © 2026 Nikola Baburov. Free software under the GNU General Public License, version 3.")
                .font(Typeface.small)
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s4)

            Rectangle().fill(Color.rule).frame(height: ControlMetrics.edge).padding(.vertical, Space.s16)

            Text("Made with")
                .font(Typeface.label)
                .foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Space.s8)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: Space.s12, verticalSpacing: Space.s4) {
                ForEach(Self.credits, id: \.name) { credit in
                    GridRow {
                        Text(credit.name).foregroundStyle(Color.ink2)
                        Text(credit.licence).foregroundStyle(Color.muted)
                    }
                    .font(Typeface.small)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: Space.s36 + Space.s8, leading: Space.s36, bottom: Space.s36, trailing: Space.s36))
        .frame(width: WindowMetrics.aboutWidth)
        .background(Color.surface)
    }
}
