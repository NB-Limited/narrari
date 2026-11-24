import Foundation

public enum HistorySettings {
    // 0 keeps history forever.
    public static let retentionDays = Setting("history.retentionDays", default: 7)
}
