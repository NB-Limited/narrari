import SwiftUI

struct TextInput: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var leadingSymbol: String?
    var isSecure = false
    var error: String?
    var focus: FocusState<Bool>.Binding?
    var onSubmit: () -> Void = {}

    @FocusState private var ownFocus: Bool

    var body: some View {
        let focus = focus ?? $ownFocus
        VStack(alignment: .leading, spacing: ControlMetrics.errorGap) {
            HStack(spacing: ControlMetrics.innerGap) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: Symbol.note))
                        .foregroundStyle(Color.muted)
                        .accessibilityHidden(true)
                }
                field
                    .textFieldStyle(.plain)
                    .font(Typeface.body)
                    .foregroundStyle(Color.ink)
                    .tint(Color.ink)
                    .focused(focus)
                    .onSubmit(onSubmit)
                    .accessibilityLabel(label)
                    .accessibilityHint(error ?? "")
            }
            .padding(.horizontal, Space.s8)
            .frame(height: ControlMetrics.fieldHeight)
            .fieldSurface(isError: error != nil)
            .focusRing(focus.wrappedValue)
            if let error {
                FormError(message: error)
            }
        }
    }

    @ViewBuilder private var field: some View {
        let prompt = Text(placeholder).foregroundStyle(Color.muted)
        if isSecure {
            SecureField(label, text: $text, prompt: prompt)
        } else {
            TextField(label, text: $text, prompt: prompt)
        }
    }
}

struct TextArea: View {
    let label: String
    @Binding var text: String
    var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.errorGap) {
            TextEditor(text: $text)
                .font(Typeface.body)
                .foregroundStyle(Color.ink)
                .tint(Color.ink)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s4)
                .frame(height: ControlMetrics.textAreaHeight)
                .fieldSurface(isError: error != nil)
                .focusRing(isFocused)
                .accessibilityLabel(label)
            if let error {
                FormError(message: error)
            }
        }
    }
}

struct FormError: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ControlMetrics.errorGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.small)
        .foregroundStyle(Color.errorInk)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

extension View {
    // The frame every field-like control shares: Surface, radius 6, a 1 pt ControlEdge border that turns 1.5 pt Error.
    func fieldSurface(isError: Bool = false, fill: Color = .surface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control).strokeBorder(
                    isError ? Color.errorInk : Color.controlEdge,
                    lineWidth: isError ? ControlMetrics.errorEdge : ControlMetrics.edge
                )
            )
    }
}
