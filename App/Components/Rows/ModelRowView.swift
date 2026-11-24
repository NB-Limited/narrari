import NarrariKit
import SwiftUI

// The models on this Mac, then those to download under a quiet head, then files no longer offered.
// Groups are set apart by spacing and their head, never a line.
struct ModelList<Model: ModelListing>: View {
    let model: Model
    let job: ModelJob
    var blockedReason: String?

    var body: some View {
        let groups = model.groups
        let readings = model.readings
        SettingsRows {
            ForEach(groups, id: \.group) { section in
                if let heading = section.group.heading {
                    ModelSubhead(text: heading, isFirst: section.group == groups.first?.group)
                }
                ForEach(section.models) { entry in
                    if model.pendingDeletion == entry.id {
                        RowBlock {
                            InlineConfirm(
                                message: model.deletionMessage(for: entry),
                                onCancel: model.cancelDeletion,
                                onConfirm: { Task { await model.confirmDeletion() } }
                            )
                        }
                    } else if section.group == .noLongerUsed {
                        LeftoverRowView(model: entry, blockedReason: blockedReason, onDelete: { model.requestDeletion(of: entry) })
                    } else {
                        ModelRowView(
                            model: entry, job: job, row: model.row(for: entry), readings: readings[entry.id] ?? [],
                            blockedReason: blockedReason,
                            onChoose: { model.choose(entry) },
                            onAction: { model.perform($0, on: entry) },
                            onDelete: { model.requestDeletion(of: entry) }
                        )
                    }
                }
                // The question in place already says how much it frees.
                if section.group == .noLongerUsed, !section.models.contains(where: { $0.id == model.pendingDeletion }) {
                    QuietLine(text: "Deleting frees the space.")
                }
            }
        }
        .padding(.top, SettingsGrid.listTop)
    }
}

private struct ModelSubhead: View {
    let text: String
    let isFirst: Bool

    var body: some View {
        Text(text)
            .font(Typeface.smallMedium)
            .foregroundStyle(Color.muted)
            .frame(minHeight: SettingsGrid.detailLine)
            .padding(.top, isFirst ? 0 : SettingsGrid.subheadTop)
            .padding(.bottom, SettingsGrid.subheadBottom)
            .accessibilityAddTraits(.isHeader)
    }
}

// Columns 18 / content / action: the radio, the name, its line and readings, then one fixed-width action column.
struct ModelRowView: View {
    let model: CatalogueModel
    let job: ModelJob
    let row: ModelRow
    let readings: [MetricReading]
    var blockedReason: String?
    let onChoose: () -> Void
    let onAction: (ModelRow.Action) -> Void
    let onDelete: () -> Void

    var body: some View {
        ModelListLine(name: model.name, mark: row.mark, isGettingReady: row.isGettingReady, blockedReason: blockedReason, onChoose: onChoose) {
            HStack(spacing: SettingsGrid.tagGap) {
                Text(model.name)
                    .font(Typeface.bodyStrong)
                    .foregroundStyle(Color.ink)
                    .frame(minHeight: SettingsGrid.nameLine)
                    .accessibilityHidden(row.mark != .unavailable)
                if model.isRecommended { Tag(text: "Recommended") }
            }
            ModelSummary(text: model.summary)
        } footer: {
            if !readings.isEmpty {
                MetricsStrip(readings: readings, job: job)
                    .padding(.top, SettingsGrid.metricsTop)
            }
            if let line = row.progressLine, let progress = row.progress {
                ModelSummary(text: line).padding(.top, Space.s4)
                ProgressBar(fraction: progress, label: "\(model.name) download", track: .meterTrack)
                    .padding(.top, SettingsGrid.progressTop)
                    .padding(.bottom, SettingsGrid.progressBottom)
            }
            if let failure = row.failure {
                FormError(message: failure).padding(.top, ControlMetrics.errorGap)
            }
        } actions: {
            if row.canDelete {
                DeleteModelButton(name: model.name, blockedReason: blockedReason, action: onDelete)
                    .meetsEdge(row.action == nil ? .trailing : [])
            }
            if let action = row.action {
                Button(Self.title(of: action)) { onAction(action) }
                    .buttonStyle(.secondary)
                    .disabled(blockedReason != nil && action != .cancel)
                    .accessibilityLabel("\(Self.title(of: action)) \(model.name)")
            }
        }
    }

    private static func title(of action: ModelRow.Action) -> String {
        switch action {
        case .download: "Download"
        case .cancel: "Cancel"
        case .retry: "Try again"
        }
    }
}

// A file the catalogue no longer lists: its name, its size and the trash, never a choice.
private struct LeftoverRowView: View {
    let model: CatalogueModel
    var blockedReason: String?
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SettingsGrid.modelGap) {
            Color.clear.frame(width: SettingsGrid.modelLead, height: SettingsGrid.nameLine)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.name)
                    .font(Typeface.body)
                    .foregroundStyle(Color.ink2)
                    .frame(minHeight: SettingsGrid.nameLine)
                ModelSummary(text: MetricText.bytes(model.metrics.diskBytes ?? 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DeleteModelButton(name: model.name, blockedReason: blockedReason, action: onDelete)
                .meetsEdge()
                .frame(height: SettingsGrid.nameLine)
        }
        .frame(maxWidth: .infinity, minHeight: SettingsGrid.rowMinHeight - 2 * SettingsGrid.rowPadding, alignment: .topLeading)
        .padding(.vertical, SettingsGrid.rowPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.name)
    }
}

// The trash at a model row's edge; while a dictation is transcribed it is off and its label says why.
private struct DeleteModelButton: View {
    let name: String
    let blockedReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "trash") }
            .buttonStyle(.icon)
            .disabled(blockedReason != nil)
            .accessibilityLabel("Delete \(name)")
            .iconLabel(blockedReason ?? "Delete \(name)")
    }
}

// The outside service as its side's only row; Set up and the pencil open its fields under the row.
struct OutsideServiceRowView<Editor: View>: View {
    let row: OutsideServiceRow
    let isEditing: Bool
    let onChoose: () -> Void
    let onSetUp: () -> Void
    @ViewBuilder var editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelListLine(name: row.name, mark: row.mark, onChoose: onChoose) {
                Text(row.name)
                    .font(Typeface.bodyStrong)
                    .foregroundStyle(Color.ink)
                    .frame(minHeight: SettingsGrid.nameLine)
                    .accessibilityHidden(row.mark != .unavailable)
                ModelSummary(text: row.summary)
                if let failure = row.failure {
                    FormError(message: failure).padding(.top, ControlMetrics.errorGap)
                }
            } footer: {
                EmptyView()
            } actions: {
                if row.showsEditButton {
                    Button(action: onSetUp) { Image(systemName: "pencil") }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Edit the \(row.name.lowercased())")
                        .iconLabel("Edit the \(row.name.lowercased())")
                        .meetsEdge()
                }
                if row.offersSetUp {
                    Button("Set up", action: onSetUp)
                        .buttonStyle(.secondary)
                        .accessibilityLabel("Set up the \(row.name.lowercased())")
                }
            }
            if isEditing {
                VStack(alignment: .leading, spacing: 0) { editor }
                    .padding(.leading, SettingsGrid.editorIndent)
                    .padding(.bottom, SettingsGrid.editorBottom)
            }
        }
    }
}

// The radio, the name and its lines, and the action column sit on the name's line in every row; the footer runs
// under both, out to the row's right edge. Clicking anywhere outside the row's buttons chooses it.
private struct ModelListLine<Content: View, Footer: View, Actions: View>: View {
    let name: String
    let mark: ChoiceMark
    var isGettingReady = false
    var blockedReason: String?
    let onChoose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @ViewBuilder var actions: Actions

    var body: some View {
        let canChoose = mark == .available && blockedReason == nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: SettingsGrid.modelGap) {
                ChoiceRadio(name: name, mark: mark, canChoose: canChoose, isGettingReady: isGettingReady, onChoose: onChoose)
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: SettingsGrid.helperGap) { actions }
                    .frame(width: SettingsGrid.actionWidth, height: SettingsGrid.nameLine, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 0) { footer }
                .padding(.leading, SettingsGrid.editorIndent)
        }
        .frame(maxWidth: .infinity, minHeight: SettingsGrid.rowMinHeight - 2 * SettingsGrid.rowPadding, alignment: .topLeading)
        .padding(.vertical, SettingsGrid.rowPadding)
        .background {
            // The model in use sits on a raised plate, where hover is a flat fill and focus a ring.
            if mark == .chosen {
                RaisedPlate(radius: Radius.control, fill: .chosenPlate)
                    .padding(.horizontal, -SettingsGrid.plateOutset)
                    .padding(.vertical, SettingsGrid.plateInset)
            }
        }
        .rowAction(isEnabled: canChoose, action: onChoose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

// Filled for the choice in use, an open ring for one that can be chosen, nothing for one that cannot be yet.
// A model getting ready keeps its filled radio; only a slow load turns it, so a quick one changes nothing.
private struct ChoiceRadio: View {
    let name: String
    let mark: ChoiceMark
    let canChoose: Bool
    let isGettingReady: Bool
    let onChoose: () -> Void
    @State private var isSlow = TimedFlag()

    var body: some View {
        ZStack {
            if isGettingReady && isSlow.isOn {
                LoadingRadio()
            } else if mark != .unavailable {
                RadioMark(isOn: mark == .chosen)
                    .opacity(mark == .chosen || canChoose ? 1 : ControlMetrics.disabledOpacity)
            }
        }
        .frame(width: SettingsGrid.modelLead, height: SettingsGrid.nameLine, alignment: .leading)
        .onChange(of: isGettingReady, initial: true) { _, isOn in
            if isOn { isSlow.turnOn(after: Motion.slowLoad) } else { isSlow.turnOff() }
        }
        .accessibilityHidden(mark == .unavailable)
        .accessibilityRepresentation {
            Picker(name, selection: Binding<Bool?>(get: { mark == .chosen ? true : nil }, set: { if $0 == true { onChoose() } })) {
                Text(name).tag(Bool?.some(true))
            }
            .pickerStyle(.radioGroup)
            .disabled(mark != .chosen && !canChoose)
            .accessibilityHint(isGettingReady ? "Getting ready" : "")
        }
    }
}

// The filled radio's ring as a 0.3 arc going round, also a running meeting step's; with Reduce Motion it holds still.
struct LoadingRadio: View {
    var colour = Color.ink
    var size = ControlMetrics.radio
    var lineWidth = ControlMetrics.radioOnEdge
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let inset = lineWidth / 2
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Motion.loadTurn) / Motion.loadTurn
            ZStack {
                Circle().inset(by: inset).stroke(colour.opacity(Motion.loadTrack), lineWidth: lineWidth)
                Circle().inset(by: inset)
                    .trim(from: 0, to: Motion.loadArc)
                    .stroke(colour, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

private struct ModelSummary: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.small.monospacedDigit())
            .foregroundStyle(Color.muted)
            .frame(minHeight: SettingsGrid.detailLine)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, SettingsGrid.summaryTop)
    }
}
