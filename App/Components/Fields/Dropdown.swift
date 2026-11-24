import AppKit
import Carbon.HIToolbox
import NarrariKit
import SwiftUI

// A popup button whose list the app draws itself: same field as before, the list in a floating panel under it.
struct Popup<Value: Hashable, Accessory: View>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var isFullWidth = false
    var accessory: ((Value) -> Accessory)?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.reducesMotion) private var reducesMotion
    @State private var anchor = Anchor()

    var body: some View {
        let title = options.first { $0.value == selection }?.title ?? ""
        Button(action: open) {
            PopupLabel(title: title, isFullWidth: isFullWidth)
        }
        .buttonStyle(.plain)
        .onKeyPress(keys: [.downArrow, .upArrow, .return, .space], phases: .down) { _ in
            open()
            return .handled
        }
        .accessibilityHidden(true)
        .background(PopupAccessibility(anchor: anchor, label: label, value: title, isEnabled: isEnabled, onPress: open))
    }

    private func open() {
        guard isEnabled, let view = anchor.view else { return }
        let rows = options.map { option in
            DropdownRow(
                title: option.title,
                accessory: accessory.map { make in AnyView(make(option.value).environment(\.reducesMotion, reducesMotion)) }
            )
        }
        Dropdown.shared.open(
            label: label, rows: rows, chosen: options.firstIndex { $0.value == selection }, from: view
        ) { index in
            selection = options[index].value
        }
    }
}

extension Popup where Accessory == EmptyView {
    init(label: String, selection: Binding<Value>, options: [(value: Value, title: String)], isFullWidth: Bool = false) {
        self.init(label: label, selection: selection, options: options, isFullWidth: isFullWidth, accessory: nil)
    }
}

struct PopupLabel: View {
    let title: String
    let isFullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: Space.s8) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: Symbol.note))
                .foregroundStyle(Color.ink2)
        }
        .font(Typeface.body)
        .foregroundStyle(Color.ink)
        .padding(.leading, ControlMetrics.popupLeading)
        .padding(.trailing, ControlMetrics.innerGap)
        .frame(width: isFullWidth ? nil : SettingsGrid.controlWidth, height: ControlMetrics.fieldHeight)
        .frame(maxWidth: isFullWidth ? .infinity : nil)
        .fieldSurface()
        .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        .opacity(isEnabled ? 1 : ControlMetrics.disabledOpacity)
        .focusRing(isFocused)
    }
}

// SwiftUI has no pop-up button role, so the anchor view is the element VoiceOver reads and presses.
private struct PopupAccessibility: NSViewRepresentable {
    let anchor: Anchor
    let label: String
    let value: String
    let isEnabled: Bool
    let onPress: () -> Void

    func makeNSView(context: Context) -> PopupAccessibilityView {
        let view = PopupAccessibilityView()
        update(view)
        return view
    }

    func updateNSView(_ view: PopupAccessibilityView, context: Context) {
        update(view)
    }

    private func update(_ view: PopupAccessibilityView) {
        anchor.view = view
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        view.setAccessibilityEnabled(isEnabled)
        view.onPress = onPress
    }
}

final class PopupAccessibilityView: PassThroughView {
    var onPress: (() -> Void)?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

struct DropdownRow {
    let title: String
    var accessory: AnyView?
    // Quiet words at the right, such as "Close match".
    var detail: String?
    // A group label above the row.
    var group: String?
    // A rule above the row.
    var startsSection = false
    var isChecked = false
    // What a row of a list with a name field does; a plain list reports the index instead.
    var action: (() -> Void)?
}

// A name field on top of the list: typing rebuilds the rows from what is typed.
struct DropdownField {
    let placeholder: String
    let rows: (String) -> [DropdownRow]
}

@MainActor
@Observable
final class DropdownState {
    var list: DropdownList
    var keyboardMoves = 0
    private(set) var rows: [DropdownRow]
    private(set) var chosen: Int?
    private(set) var typed = ""
    let field: DropdownField?
    @ObservationIgnored let choose: (Int) -> Void
    @ObservationIgnored private var pointer = NSEvent.mouseLocation

    init(rows: [DropdownRow], chosen: Int?, field: DropdownField? = nil, choose: @escaping (Int) -> Void) {
        self.rows = rows
        self.chosen = chosen
        self.field = field
        self.choose = choose
        list = DropdownList(titles: rows.map(\.title), chosen: chosen)
    }

    func type(_ change: (inout String) -> Void) {
        guard let field else { return }
        change(&typed)
        rows = field.rows(typed)
        chosen = rows.firstIndex(where: \.isChecked)
        list = DropdownList(titles: rows.map(\.title), chosen: nil)
        keyboardMoves += 1
    }

    // A row under a pointer that has not moved, because the keyboard scrolled the list, keeps the keyboard's highlight.
    func pointerEntered(_ index: Int) {
        let location = NSEvent.mouseLocation
        guard location != pointer else { return }
        pointer = location
        list.highlight(index)
    }

    func moved(_ change: (inout DropdownList) -> Void) {
        change(&list)
        keyboardMoves += 1
    }
}

// The one open dropdown list: placing it, its keys, and closing it on Escape, a click elsewhere or leaving the window.
@MainActor
final class Dropdown: NSObject, NSWindowDelegate {
    static let shared = Dropdown()

    private let panel = FloatingPanel(isKeyable: true)
    private var state: DropdownState?
    private weak var owner: NSWindow?
    private weak var anchor: NSView?
    private var alignment = AnchoredPlacement.Alignment.leading
    private var monitor: Any?

    override private init() {
        super.init()
        panel.delegate = self
        panel.setAccessibilitySubrole(.dialog)
        panel.onKey = { [weak self] event in self?.handleKey(event) }
    }

    // A popup's list lines its titles up with the popup's; an icon button's list ends on the button's trailing edge.
    func open(
        label: String, rows: [DropdownRow], chosen: Int?, from anchor: NSView, alignment: AnchoredPlacement.Alignment = .leading,
        onChoose: @escaping (Int) -> Void
    ) {
        var rows = rows
        if let chosen, rows.indices.contains(chosen) { rows[chosen].isChecked = true }
        present(label: label, rows: rows, field: nil, from: anchor, alignment: alignment, onChoose: onChoose)
    }

    // With a name field on top, at least as wide as the sidebar; each row acts by itself.
    func open(label: String, field: DropdownField, from anchor: NSView, alignment: AnchoredPlacement.Alignment = .leading) {
        present(label: label, rows: field.rows(""), field: field, from: anchor, alignment: alignment) { _ in }
    }

    private func present(
        label: String, rows: [DropdownRow], field: DropdownField?, from anchor: NSView, alignment: AnchoredPlacement.Alignment,
        onChoose: @escaping (Int) -> Void
    ) {
        close()
        guard !rows.isEmpty || field != nil, let window = anchor.window else { return }
        var state: DropdownState?
        state = DropdownState(rows: rows, chosen: rows.firstIndex(where: \.isChecked), field: field) { [weak self] index in
            let action = state?.rows[index].action
            self?.close()
            action?() ?? onChoose(index)
        }
        guard let state else { return }
        self.state = state
        owner = window
        self.anchor = anchor
        self.alignment = alignment
        panel.setAccessibilityTitle(label)
        place(state, label: label)
        panel.makeKey()
        watchPointer()
    }

    private func place(_ state: DropdownState, label: String) {
        guard let anchor else { return }
        let reach = alignment == .leading ? FloatingMetrics.titleReach : 0
        let minimum = state.field == nil ? anchor.bounds.width + reach : max(anchor.bounds.width + reach, WindowMetrics.sidebarWidth)
        panel.show(
            DropdownListView(state: state, label: label),
            size: Self.size(of: state.rows, minimumWidth: minimum, hasField: state.field != nil), anchor: anchor,
            gap: FloatingMetrics.gap, alignment: alignment, leadingReach: reach
        )
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func close() {
        guard state != nil else { return }
        state = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let returnsFocus = NSApp.keyWindow == nil || NSApp.keyWindow === panel
        panel.hide()
        if returnsFocus { owner?.makeKey() }
        owner = nil
    }

    // A click outside closes the list without acting on what was clicked, as a menu does.
    private func watchPointer() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self, event.window !== panel else { return event }
            close()
            return event.type == .scrollWheel ? event : nil
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard let state else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if state.field != nil, handleTyping(event, modifiers: modifiers, in: state) { return }
        switch Int(event.keyCode) {
        case kVK_DownArrow: state.moved { $0.move(by: 1) }
        case kVK_UpArrow: state.moved { $0.move(by: -1) }
        case kVK_Home, kVK_PageUp: state.moved { $0.moveToEnd(last: false) }
        case kVK_End, kVK_PageDown: state.moved { $0.moveToEnd(last: true) }
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let index = state.list.highlighted { state.choose(index) }
        case kVK_Escape: close()
        case kVK_ANSI_Period where modifiers == .command: close()
        default:
            guard modifiers.isEmpty, let text = event.characters, text.unicodeScalars.allSatisfy(Self.typeable) else { return }
            state.moved { $0.type(text, at: event.timestamp) }
        }
    }

    // In a list with a name field, letters and Space go into the field and the list follows it.
    private func handleTyping(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, in state: DropdownState) -> Bool {
        if Int(event.keyCode) == kVK_Delete {
            state.type { if !$0.isEmpty { $0.removeLast() } }
        } else if modifiers.isEmpty, let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy(Self.typeable) {
            state.type { $0 += text }
        } else {
            return false
        }
        place(state, label: panel.accessibilityTitle() ?? "")
        return true
    }

    private static func typeable(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }

    static func size(of rows: [DropdownRow], minimumWidth: CGFloat, hasField: Bool = false) -> CGSize {
        let longest = rows.map { row in
            (row.title as NSString).size(withAttributes: [.font: Typeface.bodyFont]).width
                + (row.detail.map { ($0 as NSString).size(withAttributes: [.font: Typeface.labelMediumFont]).width + Space.s8 } ?? 0)
        }.max() ?? 0
        let accessory = rows.contains { $0.accessory != nil } ? ControlMetrics.iconButton + FloatingMetrics.checkGap : 0
        let content = FloatingMetrics.checkColumn + FloatingMetrics.checkGap + ceil(longest) + Space.s4 + accessory
        let scrolls = rows.count > FloatingMetrics.maxRows
        // With a mouse attached the scroll bar takes its own column; overlay scroll bars take none.
        let scroller = scrolls ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle) : 0
        let width = content + 2 * (FloatingMetrics.rowPadding + FloatingMetrics.listInset) + scroller
        // A long list stops halfway through a row, so the cut row says there is more.
        let visibleRows = scrolls ? CGFloat(FloatingMetrics.maxRows) + 0.5 : CGFloat(rows.count)
        let shown = rows.prefix(Int(visibleRows.rounded(.up)))
        let heads = CGFloat(shown.count { $0.group != nil }) * FloatingMetrics.groupHeight
            + CGFloat(shown.count { $0.startsSection }) * FloatingMetrics.sectionHeight
        return CGSize(
            width: min(max(width, minimumWidth), max(minimumWidth, FloatingMetrics.maxListWidth)),
            height: visibleRows * FloatingMetrics.rowHeight + heads + (hasField ? FloatingMetrics.fieldHeight : 0) + 2 * FloatingMetrics.listInset
        )
    }
}

struct DropdownListView: View {
    let state: DropdownState
    let label: String
    @AccessibilityFocusState private var focusedRow: Int?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FloatingMetrics.radius)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let field = state.field {
                        DropdownFieldView(text: state.typed, placeholder: field.placeholder)
                    }
                    ForEach(state.rows.indices, id: \.self) { index in
                        let row = state.rows[index]
                        if row.startsSection {
                            Rectangle().fill(Color.rule).frame(height: ControlMetrics.edge)
                                .padding(.vertical, Space.s4).padding(.horizontal, FloatingMetrics.rowPadding)
                        }
                        if let group = row.group {
                            Text(group)
                                .font(Typeface.label)
                                .tracking(Typeface.groupTracking)
                                .foregroundStyle(Color.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: 9, leading: FloatingMetrics.groupIndent, bottom: 5, trailing: FloatingMetrics.rowPadding))
                                .accessibilityAddTraits(.isHeader)
                        }
                        DropdownRowView(state: state, index: index)
                            .id(index)
                            .accessibilityFocused($focusedRow, equals: index)
                    }
                }
                .padding(FloatingMetrics.listInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear {
                if let row = state.list.highlighted {
                    proxy.scrollTo(row, anchor: .center)
                    focusedRow = row
                }
            }
            .onChange(of: state.keyboardMoves) {
                guard let row = state.list.highlighted else { return }
                proxy.scrollTo(row)
                focusedRow = row
            }
        }
        .background(Color.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.rule, lineWidth: FloatingMetrics.edge))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct DropdownRowView: View {
    let state: DropdownState
    let index: Int

    var body: some View {
        let row = state.rows[index]
        let isChosen = index == state.chosen || row.isChecked
        Button { state.choose(index) } label: {
            HStack(spacing: FloatingMetrics.checkGap) {
                Image(systemName: "checkmark")
                    .font(.system(size: Symbol.note, weight: .semibold))
                    .opacity(isChosen ? 1 : 0)
                    .frame(width: FloatingMetrics.checkColumn)
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = row.detail {
                    Text(detail).font(Typeface.labelMedium).foregroundStyle(Color.muted)
                }
                if row.accessory != nil {
                    Color.clear.frame(width: ControlMetrics.iconButton)
                }
            }
            .font(Typeface.body)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, FloatingMetrics.rowPadding)
            .frame(height: FloatingMetrics.rowHeight)
            .background(
                state.list.highlighted == index ? Color.selectionFill : .clear,
                in: RoundedRectangle(cornerRadius: Radius.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { if $0 { state.pointerEntered(index) } }
        .accessibilityLabel(row.detail.map { "\(row.title), \($0)" } ?? row.title)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .overlay(alignment: .trailing) {
            if let accessory = row.accessory {
                accessory.padding(.trailing, FloatingMetrics.rowPadding - Space.s4)
            }
        }
    }
}

// The name field on top of a list: it shows what is typed; the list's own keys do the typing, so it never takes focus.
private struct DropdownFieldView: View {
    let text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 0) {
            Text(text.isEmpty ? placeholder : text)
                .foregroundStyle(text.isEmpty ? Color.muted : Color.ink)
                .lineLimit(1)
                .truncationMode(.head)
            Rectangle().fill(Color.ink).frame(width: 1, height: Symbol.window)
            Spacer(minLength: 0)
        }
        .font(Typeface.body)
        .padding(.horizontal, Space.s8)
        .frame(height: ControlMetrics.fieldHeight)
        .fieldSurface()
        .focusRing(true)
        .padding(Space.s2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeholder)
        .accessibilityValue(text)
    }
}
