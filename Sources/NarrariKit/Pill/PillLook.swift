import Foundation

// The order is the order of the Recorder look list: the glass looks, the dark looks, then the smaller recorders.
public enum PillLook: String, CaseIterable, Sendable {
    case smoked
    case clear
    case solid
    case gloss
    case colour
    case halo
    case compact
    case inline

    public var name: String {
        switch self {
        case .smoked: "Smoked"
        case .clear: "Clear"
        case .solid: "Solid"
        case .gloss: "Gloss"
        case .colour: "Colour"
        case .halo: "Halo"
        case .compact: "Compact"
        case .inline: "Inline"
        }
    }

    public var recorder: PillRecorder {
        switch self {
        case .smoked, .clear, .solid, .gloss, .colour, .halo: .full
        case .compact: .bars
        case .inline: .words
        }
    }

    // Reduce Transparency takes the glass away; the opaque looks keep their own finish.
    public func finish(reduceTransparency: Bool) -> PillFinish {
        switch self {
        case .smoked, .halo: reduceTransparency ? .solid : .smoked
        case .clear: reduceTransparency ? .solid : .clear
        case .gloss: .gloss
        case .solid, .colour, .compact, .inline: .solid
        }
    }

    public var isColoured: Bool {
        self == .colour
    }

    // Halo draws the level and the work as light on the capsule's outline, and dims the words before the newest.
    public var hasHalo: Bool {
        self == .halo
    }

    public var hasPlate: Bool {
        recorder != .words
    }
}

public enum PillFinish: Sendable {
    case smoked
    case clear
    case solid
    case gloss
}

// What the capsule shows while recording: the full row, the level bars alone, or the bars with the words beside them.
public enum PillRecorder: Sendable {
    case full
    case bars
    case words
}

extension PillLook {
    // Logged with each dictation, so a report says which recorder was on screen.
    func logForDictation() {
        switch self {
        case .smoked: Log.event("recorder-look-smoked")
        case .clear: Log.event("recorder-look-clear")
        case .solid: Log.event("recorder-look-solid")
        case .gloss: Log.event("recorder-look-gloss")
        case .colour: Log.event("recorder-look-colour")
        case .halo: Log.event("recorder-look-halo")
        case .compact: Log.event("recorder-look-compact")
        case .inline: Log.event("recorder-look-inline")
        }
    }
}
