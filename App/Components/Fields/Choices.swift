import SwiftUI

struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }
}

private struct SwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @FocusState private var isFocused: Bool

    var body: some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .tint(.switchOn)
            .controlSize(.small)
            .focused($isFocused)
            .focusEffectDisabled()
            .focusRing(isFocused, radius: ControlMetrics.switchHeight / 2)
    }
}

// A 15 pt ring: ControlEdge when off, a 4.5 pt Ink ring when on.
struct RadioButton: View {
    let isOn: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { RadioMark(isOn: isOn) }
            .buttonStyle(RadioButtonStyle())
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(Color.surface)
            .overlay(Circle().strokeBorder(isOn ? Color.ink : Color.controlEdge, lineWidth: isOn ? ControlMetrics.radioOnEdge : ControlMetrics.edge))
            .frame(width: ControlMetrics.radio, height: ControlMetrics.radio)
    }
}

private struct RadioButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RadioButtonBody(configuration: configuration)
    }
}

private struct RadioButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? ControlMetrics.pressedOpacity : 1) : ControlMetrics.disabledOpacity)
            .focusRing(isFocused, radius: ControlMetrics.radio / 2)
    }
}

extension ToggleStyle where Self == SwitchStyle {
    static var narrariSwitch: SwitchStyle { SwitchStyle() }
}
