import NarrariKit
import SwiftUI

// The "Built in" and "Yours" groups, one layout for the prompts and the summary templates.
struct BuiltInListGroups<Model: BuiltInList, Lead: View, Editor: View>: View {
    let model: Model
    // "prompt" makes "Add prompt".
    let noun: String
    let deleteQuestion: (_ name: String) -> String
    var tag: (Model.Item) -> String? = { _ in nil }
    // Buttons before the row's own, such as making a template the default.
    @ViewBuilder var lead: (Model.Item) -> Lead
    @ViewBuilder var editor: () -> Editor

    @State private var openItems: Set<String> = []

    private static var newEditor: String { "new-editor" }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                FormGroup(label: "Built in") {
                    SettingsRows {
                        ForEach(model.builtIn) { item in
                            row(item) {
                                Button { model.startDuplicating(item.id) } label: { Image(systemName: "plus.square.on.square") }
                                    .buttonStyle(.icon)
                                    .disabled(model.editing != nil)
                                    .accessibilityLabel("Duplicate \(item.name)")
                                    .iconLabel(model.editing != nil ? "Finish editing first" : "Duplicate \(item.name)")
                                    .meetsEdge()
                            }
                        }
                    }
                }
                yoursGroup
            }
            .onChange(of: model.editing) { _, editing in
                if editing == .new { proxy.scrollTo(Self.newEditor) }
            }
        }
    }

    private var yoursGroup: some View {
        FormGroup(label: "Yours") {
            if model.editing == nil {
                Button("Add \(noun)", action: model.startAdding).buttonStyle(.secondary)
            }
        } content: {
            SettingsRows {
                ForEach(model.yours) { item in
                    yourRow(item)
                }
                ForEach(model.unreadable, id: \.self) { id in
                    unreadableRow(id)
                }
                if model.editing == .new {
                    RowBlock(bottom: SettingsGrid.editorBottom) { editor() }
                        .id(Self.newEditor)
                }
            }
            if model.yours.isEmpty, model.unreadable.isEmpty, model.editing != .new {
                QuietLine(text: "None yet.")
            }
        }
    }

    @ViewBuilder private func yourRow(_ item: Model.Item) -> some View {
        if model.editing == .item(item.id) {
            RowBlock(bottom: SettingsGrid.editorBottom) { editor() }
        } else if model.pendingDeletion == item.id {
            confirmDeletion(of: item.name)
        } else {
            row(item) {
                Button { model.requestDeletion(item.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.icon)
                    .accessibilityLabel("Delete \(item.name)")
                    .iconLabel("Delete \(item.name)")
                Button { model.startEditing(item.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.icon)
                    .accessibilityLabel("Edit \(item.name)")
                    .iconLabel("Edit \(item.name)")
                    .meetsEdge()
            }
        }
    }

    // A file of yours that could not be read stays on the list, so it can be deleted rather than vanish.
    @ViewBuilder private func unreadableRow(_ id: String) -> some View {
        let name = "\(id).md"
        if model.pendingDeletion == id {
            confirmDeletion(of: name)
        } else {
            RowBlock {
                RowLine(title: name, isStrong: true) {
                    Button { model.requestDeletion(id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Delete \(name)")
                        .iconLabel("Delete \(name)")
                        .meetsEdge()
                }
                FormError(message: "This file could not be read.").padding(.top, ControlMetrics.errorGap)
            }
            .padding(.leading, SettingsGrid.modelLead + SettingsGrid.modelGap)
        }
    }

    private func confirmDeletion(of name: String) -> some View {
        RowBlock {
            InlineConfirm(message: deleteQuestion(name), onCancel: model.cancelDeletion, onConfirm: model.confirmDeletion)
        }
    }

    private func row(_ item: Model.Item, @ViewBuilder actions: () -> some View) -> some View {
        OpeningRow(name: item.name, detail: item.listDetail, text: item.fullText, tag: tag(item), isOpen: isOpen(item)) {
            lead(item)
            actions()
        }
    }

    private func isOpen(_ item: Model.Item) -> Binding<Bool> {
        Binding {
            openItems.contains(item.id)
        } set: { isOpen in
            if isOpen { openItems.insert(item.id) } else { openItems.remove(item.id) }
        }
    }
}

extension BuiltInListGroups where Lead == EmptyView {
    init(model: Model, noun: String, deleteQuestion: @escaping (_ name: String) -> String, @ViewBuilder editor: @escaping () -> Editor) {
        self.init(model: model, noun: noun, deleteQuestion: deleteQuestion, lead: { _ in EmptyView() }, editor: editor)
    }
}

// The editor both lists open in place: a name, the text, and what else the item needs.
struct ListItemEditor<Extra: View>: View {
    let noun: String
    @Binding var name: String
    let nameError: String?
    let textLabel: String
    @Binding var text: String
    let textError: String?
    let onDone: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var extra: Extra

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel(text: "Name", isFirst: true)
            TextInput(label: "\(noun.capitalized) name", text: $name, error: nameError, focus: $isNameFocused)
            FieldLabel(text: textLabel)
            TextArea(label: textLabel, text: $text, error: textError)
            extra
            EditorActions(onDone: onDone, onCancel: onCancel)
        }
        .onAppear { isNameFocused = true }
        .takesEscape()
    }
}
