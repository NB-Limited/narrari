import Foundation

// A meeting whose day is more than the set number of days ago loses its audio; its text stays.
public enum MeetingRetention {
    public static func run(on store: MeetingStore, settings: SettingsStore, now: Date) async throws {
        guard let cutoff = cutoff(days: settings.value(MeetingsSettings.audioRetentionDays), now: now, calendar: store.calendar) else { return }
        try await store.removeAudio(startedBefore: cutoff)
    }

    // What a run at this many days would take audio from.
    static func meetings(olderThan days: Int, in store: MeetingStore, now: Date) async throws -> Int {
        guard let cutoff = cutoff(days: days, now: now, calendar: store.calendar) else { return 0 }
        return try await store.meetingsWithAudio(startedBefore: cutoff)
    }

    private static func cutoff(days: Int, now: Date, calendar: Calendar) -> Date? {
        guard days > 0 else { return nil }
        return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
    }
}
