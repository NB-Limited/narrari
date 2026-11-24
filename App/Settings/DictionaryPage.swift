import NarrariKit
import SwiftUI

struct DictionaryPage: View {
    @Bindable var model: DictionaryPageModel

    var body: some View {
        SettingsPage(title: "Dictionary", subtitle: "Spellings and fixed phrases.") {
            FileNotice(file: model.file, storeError: model.storeError, onStartFresh: model.startFresh)
            Group {
                FormGroup(label: "Words to spell right") {
                    AddLine(label: "Add word", isDisabled: model.newWord.trimmingCharacters(in: .whitespaces).isEmpty, onAdd: model.addWord) {
                        TextInput(label: "New word", text: $model.newWord, placeholder: "A name or term", error: model.wordError, onSubmit: model.addWord)
                    }
                    listening
                    if !model.list.words.isEmpty {
                        SettingsRows {
                            ForEach(model.list.words, id: \.self) { word in
                                SettingsRow(title: word) {
                                    Button { model.removeWord(word) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.icon)
                                        .accessibilityLabel("Remove \(word)")
                                        .iconLabel("Remove \(word)")
                                        .meetsEdge()
                                }
                            }
                        }
                        .padding(.top, SettingsGrid.listTop)
                    }
                }

                FormGroup(label: "Replacements") {
                    AddLine(label: "Add replacement", isDisabled: model.newPhrase.isEmpty && model.newText.isEmpty, onAdd: model.addReplacement) {
                        TextInput(label: "When you say", text: $model.newPhrase, placeholder: "When you say")
                        PhraseArrow().frame(height: ControlMetrics.fieldHeight)
                        TextInput(label: "Paste", text: $model.newText, placeholder: "Paste", onSubmit: model.addReplacement)
                    }
                    if let error = model.replacementError {
                        FormError(message: error).padding(.top, ControlMetrics.errorGap)
                    }
                    if !model.list.replacements.isEmpty {
                        SettingsRows {
                            ForEach(Array(model.list.replacements.enumerated()), id: \.offset) { index, replacement in
                                PhraseRow(model: model, row: .replacement(index), phrase: replacement.phrase, result: replacement.text, resultLabel: "Paste") {
                                    TextInput(label: "Paste", text: $model.editText, onSubmit: model.commitEditing)
                                }
                            }
                        }
                        .padding(.top, SettingsGrid.listTop)
                    }
                }

                FormGroup(label: "Spoken marks") {
                    SwitchRow(title: "Write a mark when you say its phrase", isOn: $model.writesSpokenMarks)
                    if model.writesSpokenMarks {
                        AddLine(label: "Add spoken mark", isDisabled: model.newMarkPhrase.trimmingCharacters(in: .whitespaces).isEmpty, onAdd: model.addMark) {
                            TextInput(label: "When you say", text: $model.newMarkPhrase, placeholder: "When you say", onSubmit: model.addMark)
                            PhraseArrow().frame(height: ControlMetrics.fieldHeight)
                            Popup(label: "Write", selection: $model.newMark, options: Self.marks)
                        }
                        if let error = model.markError {
                            FormError(message: error).padding(.top, ControlMetrics.errorGap)
                        }
                        if !model.list.marks.isEmpty {
                            SettingsRows {
                                ForEach(Array(model.list.marks.enumerated()), id: \.offset) { index, mark in
                                    PhraseRow(model: model, row: .mark(index), phrase: mark.phrase, result: mark.mark.name, resultLabel: "Write") {
                                        Popup(label: "Write", selection: $model.editMark, options: Self.marks, isFullWidth: true)
                                    }
                                }
                            }
                            .padding(.top, SettingsGrid.listTop)
                        }
                    }
                }
            }
            .disabled(model.file.isUnreadable)
        }
        .onAppear(perform: model.appear)
    }

    private static let marks = SpokenMark.Mark.allCases.map { (value: $0, title: $0.name) }

    // At most one quiet line: before the first word, while getting ready, or when that failed.
    @ViewBuilder private var listening: some View {
        if let line = model.listeningLine {
            if model.listening == .failed {
                HStack(alignment: .top, spacing: SettingsGrid.rowGap) {
                    FormError(message: line)
                        .padding(.top, Space.s4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Try again", action: model.retryListening).buttonStyle(.secondary)
                }
                .padding(.top, ControlMetrics.errorGap)
            } else {
                QuietLine(text: line).monospacedDigit()
            }
        }
    }
}

private struct PhraseArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: Symbol.note))
            .foregroundStyle(Color.muted)
            .accessibilityHidden(true)
    }
}

// A phrase and what it becomes, with Remove and Edit; the editor's second field is the list's own.
private struct PhraseRow<Editor: View>: View {
    @Bindable var model: DictionaryPageModel
    let row: DictionaryPageModel.Row
    let phrase: String
    let result: String
    let resultLabel: String
    @ViewBuilder var editor: Editor

    var body: some View {
        if model.editing == row {
            RowBlock(bottom: SettingsGrid.editorBottom) {
                FieldPair {
                    FieldLabel(text: "When you say", isFirst: true)
                    TextInput(label: "When you say", text: $model.editPhrase)
                } trailing: {
                    FieldLabel(text: resultLabel, isFirst: true)
                    editor
                }
                if let error = model.editError {
                    FormError(message: error).padding(.top, ControlMetrics.errorGap)
                }
                EditorActions(onDone: model.commitEditing, onCancel: model.cancelEditing)
            }
            .takesEscape()
        } else {
            RowBlock {
                HStack(spacing: SettingsGrid.controlGap) {
                    Text(phrase).font(Typeface.body).foregroundStyle(Color.ink).lineLimit(1)
                    PhraseArrow()
                    Text(result).font(Typeface.body).foregroundStyle(Color.ink2).lineLimit(1)
                    Spacer(minLength: SettingsGrid.rowGap)
                    HStack(spacing: SettingsGrid.helperGap) {
                        Button { model.remove(row) } label: { Image(systemName: "trash") }
                            .buttonStyle(.icon)
                            .accessibilityLabel("Remove \(phrase)")
                            .iconLabel("Remove \(phrase)")
                        Button { model.startEditing(row) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.icon)
                            .accessibilityLabel("Edit \(phrase)")
                            .iconLabel("Edit \(phrase)")
                            .meetsEdge()
                    }
                }
                .frame(minHeight: ControlMetrics.fieldHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(phrase) becomes \(result)")
            }
        }
    }
}
