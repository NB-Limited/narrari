import Foundation
import NarrariKit
import Testing

// The state hues and the fill are read from the app's colour catalogue, so a change there is checked here too.
struct PillColourTests {
    private static let contrastFloor = 4.5
    // OKLab distance: what the listening blue keeps from the cleaning violet under Increase Contrast, the closest pair the design shows.
    private static let distanceFloor = 0.06

    @Test func every_preset_is_readable_on_the_pill_fill() throws {
        let fill = try Catalogue.colour("PillFill")
        for preset in PillColour.allCases {
            for hex in [preset.hex, preset.highContrastHex] {
                #expect(Swatch(hex).contrast(with: fill.normal) >= Self.contrastFloor, "\(preset.name) \(String(hex, radix: 16))")
            }
        }
    }

    @Test func every_preset_stays_apart_from_the_cleaning_and_done_hues() throws {
        let states = try [Catalogue.colour("PillClean"), Catalogue.colour("PillDone")]
        for preset in PillColour.allCases {
            for state in states {
                #expect(Swatch(preset.hex).distance(to: state.normal) >= Self.distanceFloor, "\(preset.name)")
                #expect(Swatch(preset.highContrastHex).distance(to: state.high) >= Self.distanceFloor, "\(preset.name), high contrast")
            }
        }
    }
}

private struct Swatch {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double(hex >> 16 & 0xFF) / 255
        green = Double(hex >> 8 & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    func contrast(with other: Swatch) -> Double {
        let (light, dark) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    private var oklab: [Double] {
        let (r, g, b) = (Self.linear(red), Self.linear(green), Self.linear(blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return [
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        ]
    }

    func distance(to other: Swatch) -> Double {
        sqrt(zip(oklab, other.oklab).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
    }
}

private enum Catalogue {
    private struct File: Decodable {
        let colors: [Entry]
    }

    fileprivate struct Entry: Decodable {
        let appearances: [CatalogueAppearance]?
        let color: CatalogueColour
    }

    private static let folder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/Assets.xcassets/Colors")

    static func colour(_ name: String) throws -> (normal: Swatch, high: Swatch) {
        let data = try Data(contentsOf: folder.appending(path: "\(name).colorset/Contents.json"))
        let entries = try JSONDecoder().decode(File.self, from: data).colors
        let normal = try #require(entries.first { $0.appearances == nil })
        let high = entries.first { $0.appearances?.contains { $0.value == "high" } == true } ?? normal
        return try (swatch(normal), swatch(high))
    }

    private static func swatch(_ entry: Entry) throws -> Swatch {
        let hex = try ["red", "green", "blue"].map { key in
            try #require(entry.color.components[key].flatMap { UInt32($0.dropFirst(2), radix: 16) })
        }
        return Swatch(hex[0] << 16 | hex[1] << 8 | hex[2])
    }
}

private struct CatalogueAppearance: Decodable {
    let value: String
}

private struct CatalogueColour: Decodable {
    let components: [String: String]
}
