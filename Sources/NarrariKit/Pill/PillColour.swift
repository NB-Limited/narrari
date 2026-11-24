import Foundation

// The Colour look's hue while listening and transcribing. Cleaning up and done keep their own hues, because those mean a state.
public enum PillColour: String, CaseIterable, Sendable {
    case blue
    case teal
    case lime
    case yellow
    case amber
    case pink

    public var name: String {
        switch self {
        case .blue: "Blue"
        case .teal: "Teal"
        case .lime: "Lime"
        case .yellow: "Yellow"
        case .amber: "Amber"
        case .pink: "Pink"
        }
    }

    public var hex: UInt32 {
        switch self {
        case .blue: 0x7AB8F5
        case .teal: 0x58CCDC
        case .lime: 0xB8E06E
        case .yellow: 0xEDD66A
        case .amber: 0xF5B567
        case .pink: 0xF28DC7
        }
    }

    // Under Increase Contrast.
    public var highContrastHex: UInt32 {
        switch self {
        case .blue: 0xA6D0FA
        case .teal: 0x92DEE8
        case .lime: 0xD1EBA1
        case .yellow: 0xF3E49E
        case .amber: 0xF8CF9C
        case .pink: 0xF7B5DB
        }
    }
}
