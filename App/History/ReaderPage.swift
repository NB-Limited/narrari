import AppKit
import NarrariKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderPage: View {
    let entry: HistoryEntry
    let library: HistoryLibrary
    let playback: AudioPlayback
    @Binding var isDetailsOpen: Bool

    var body: some View {
        let hasAudio = library.hasAudio(entry)
        let isWorking = library.retranscribing.contains(entry.id)
        VStack(spacing: 0) {
            ReaderToolbar(
                entry: entry, library: library, playback: playback, hasAudio: hasAudio, isWorking: isWorking,
                isCleaning: library.cleaningUp[entry.id] != nil
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MetaLine {
                        WhenText(entry: entry)
                        Text(EntryFormat.length(entry))
                    }
                    notes(isWorking: isWorking)
                    if entry.needsTranscription, hasAudio {
                        Button("Transcribe") { Task { await library.retranscribe(entry) } }
                            .buttonStyle(.primary)
                            .disabled(isWorking)
                            .padding(.top, Space.s14)
                    } else {
                        Text(entry.finalText)
                            .font(Typeface.said)
                            .tracking(Typeface.saidTracking)
                            .lineSpacing(Typeface.saidLineSpacing)
                            .foregroundStyle(Color.ink)
                            .textSelection(.enabled)
                            .padding(.top, Space.s14)
                            .accessibilityLabel(entry.finalText)
                    }
                    DisclosureButton(title: "Details", isOpen: $isDetailsOpen)
                        .meetsEdge(.leading)
                        .padding(.top, Space.s16)
                    if isDetailsOpen {
                        details.transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: Space.s4, leading: Space.s36, bottom: Space.s22, trailing: Space.s36))
            }
            if hasAudio {
                AudioBar(playback: playback)
            }
        }
        .task(id: entry.id) {
            playback.load(hasAudio ? [library.audioURL(for: entry)] : [], expectedDuration: Double(entry.durationMs) / 1000)
        }
    }

    // Only what needs attention stays above the text; a clean-up turned off on purpose is told in the details.
    @ViewBuilder private func notes(isWorking: Bool) -> some View {
        let lines: [(symbol: String, text: String)] = [
            entry.outcomeNote.map { ("exclamationmark.circle", $0) },
            entry.isCleanupSkipped ? entry.cleanupNote.map { ("exclamationmark.circle", $0) } : nil,
            entry.speechFallbackNote.map { ("network.slash", $0) },
            isWorking ? ("waveform", "Transcribing again") : nil,
            library.cleaningUp[entry.id].map { ("text.alignleft", $0.runningLabel) }
        ].compactMap { $0 }
        if !lines.isEmpty || library.errors[entry.id] != nil {
            VStack(alignment: .leading, spacing: Space.s4) {
                ForEach(lines, id: \.text) { line in
                    Label(line.text, systemImage: line.symbol)
                        .labelStyle(TightLabelStyle())
                        .font(Typeface.small)
                        .foregroundStyle(Color.ink2)
                }
                if let error = library.errors[entry.id] {
                    FormError(message: error)
                }
            }
            .padding(.top, Space.s8)
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetaLine {
                SourceLabel(entry: entry, apps: library.apps)
                if !entry.mode.isEmpty {
                    Text(entry.mode)
                }
            }
            .padding(.top, Space.s4)
            if let edits = entry.cleanupEdits {
                HeardText(heard: entry.rawText, segments: edits)
            }
            if let line = entry.madeWith(appName: library.apps.name(for: entry.app)) {
                SectionLabel(text: "Made with")
                Text(line)
                    .font(Typeface.small)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MetaLine<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Space.s16) { content }
            .font(Typeface.small)
            .foregroundStyle(Color.muted)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }
}

private struct WhenText: View {
    let entry: HistoryEntry

    var body: some View {
        Text(EntryFormat.when(entry))
            .fontWeight(.semibold)
            .foregroundStyle(Color.ink2)
    }
}

private struct SourceLabel: View {
    let entry: HistoryEntry
    let apps: AppDirectory

    var body: some View {
        HStack(spacing: Space.s4) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: Symbol.window, height: Symbol.window)
                    .accessibilityHidden(true)
            }
            Text(EntryFormat.source(entry, apps: apps))
                .truncationMode(.middle)
        }
    }

    // A file shows the icon of its kind, as Finder would; a dictation the app's.
    private var icon: NSImage? {
        guard let file = entry.file else { return apps.app(for: entry.app).icon }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (file as NSString).pathExtension) ?? .audio)
    }
}

// A file being transcribed: where it came from, how far it is, and a way to stop.
struct FileProgressPage: View {
    let entry: HistoryEntry
    let running: FileJob.Running
    let apps: AppDirectory
    let onCancel: () -> Void

    var body: some View {
        let fraction = running.fraction
        let label = "Transcribing, \(MetricText.percent(fraction))"
        VStack(spacing: 0) {
            Color.clear.frame(height: WindowMetrics.toolbarHeight)
            VStack(alignment: .leading, spacing: 0) {
                MetaLine {
                    WhenText(entry: entry)
                    SourceLabel(entry: entry, apps: apps)
                }
                Label(label, systemImage: "waveform")
                    .labelStyle(TightLabelStyle())
                    .font(Typeface.small)
                    .foregroundStyle(Color.ink2)
                    .padding(.top, Space.s8)
                ProgressBar(fraction: fraction, label: label)
                    .padding(.top, Space.s8)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, Space.s14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: Space.s4, leading: Space.s36, bottom: Space.s22, trailing: Space.s36))
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.label)
            .foregroundStyle(Color.muted)
            .padding(.top, Space.s22)
            .padding(.bottom, Space.s4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct HeardText: View {
    let heard: String
    let segments: [TextDiff.Segment]

    var body: some View {
        SectionLabel(text: "As heard, with what clean-up removed")
        Text(attributed(segments))
            .font(Typeface.heard)
            .lineSpacing(Typeface.heardLineSpacing)
            .foregroundStyle(Color.ink2)
            .textSelection(.enabled)
            .accessibilityLabel(heard)
            .accessibilityValue(removedSummary(segments))
    }

    private func attributed(_ segments: [TextDiff.Segment]) -> AttributedString {
        var text = AttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { text += AttributedString(" ") }
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .kept: break
            case .removed:
                part.foregroundColor = .muted
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .muted)
            case .inserted:
                part.underlineStyle = Text.LineStyle(pattern: .solid, color: .muted)
            }
            text += part
        }
        return text
    }

    private func removedSummary(_ segments: [TextDiff.Segment]) -> String {
        let removed = segments.filter { $0.kind == .removed }.map(\.text)
        return removed.isEmpty ? "" : "Clean-up removed: \(removed.joined(separator: ", "))"
    }
}
