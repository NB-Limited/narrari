import Foundation

public enum PillSettings {
    public static let look = Setting("pill.look", default: PillLook.smoked)
    public static let colour = Setting("pill.colour", default: PillColour.blue)
}
