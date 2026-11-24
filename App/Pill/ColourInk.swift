import NarrariKit
import SwiftUI

extension EnvironmentValues {
    // Set only in the Colour look; nil keeps PillText.
    @Entry var pillAccent: Color?
}

// The Colour look: Solid's capsule, with the state's symbol, bars and dots in one hue.
// Every state keeps its own symbol and words, so none rests on colour alone.
enum PillAccent {
    static func colour(of layer: PillCapsule, listening: Color) -> Color? {
        switch layer {
        case .recording: listening
        case .working(let label): label == .cleaning ? .pillClean : listening
        case .done: .pillDone
        case .notice: nil
        }
    }
}

extension PillColour {
    func color(highContrast: Bool) -> Color {
        let hex = highContrast ? highContrastHex : self.hex
        return Color(
            .sRGB,
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
