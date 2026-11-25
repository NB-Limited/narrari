import Foundation

public enum MeetingFormat {
    static let listedPeople = 3

    // "10:00" today, "Yesterday 08:30", "Tue 14:30" this week, "12 Nov 14:30" before that.
    public static func time(_ date: Date, now: Date, calendar: Calendar = HistoryStore.localCalendar) -> String {
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days == 0 { return clock }
        if days == 1 { return "Yesterday \(clock)" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
        style = days < 7 ? style.weekday(.abbreviated) : style.day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return "\(date.formatted(style)) \(clock)"
    }

    public static func when(_ date: Date, now: Date, calendar: Calendar = HistoryStore.localCalendar) -> String {
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        return "\(HistoryDay.title(for: date, now: now, calendar: calendar)), \(clock)"
    }

    // A meeting with no calendar event has no title until it is given one.
    public static func title(_ meeting: Meeting) -> String {
        meeting.title.isEmpty ? "Untitled meeting" : meeting.title
    }

    public static func length(milliseconds: Int) -> String {
        let minutes = max(1, Int((Double(milliseconds) / 60_000).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h " + String(format: "%02d", minutes % 60) + " min"
    }

    // The people heard by name, then those invited; the owner, also as an older meeting's invite lists them, and
    // numbered speakers are left out.
    public static func people(of meeting: Meeting) -> [String] {
        var names: [String] = []
        let owner = meeting.speakers.first { $0.id == MeetingTranscript.ownerID }.map { OwnerName($0.name) }
        let others = meeting.speakers.filter { $0.id != MeetingTranscript.ownerID && !isNumbered($0) }.map(\.name)
        for name in others + meeting.attendees.map(\.name).filter({ owner?.matches($0) != true })
        where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        return names
    }

    public static func listedPeople(of meeting: Meeting) -> String {
        let names = people(of: meeting)
        let shown = names.prefix(listedPeople).joined(separator: ", ")
        return names.count > listedPeople ? "\(shown), +\(names.count - listedPeople)" : shown
    }

    // "Maria Petrova, Jonas Weber and you"; nil when nobody is known by name.
    public static func pagePeople(of meeting: Meeting) -> String? {
        let names = people(of: meeting)
        guard !names.isEmpty else { return nil }
        guard meeting.source != .import else { return names.joined(separator: ", ") }
        return names.joined(separator: ", ") + " and you"
    }

    public static func isNumbered(_ speaker: Meeting.Speaker) -> Bool {
        speaker.name.wholeMatch(of: /Speaker \d+/) != nil
    }

    // An unreadable folder's date, from the stamp its name starts with.
    public static func folderDate(_ folder: URL, calendar: Calendar = HistoryStore.localCalendar) -> Date? {
        let stamp = String(folder.lastPathComponent.prefix(15))
        let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)
        var strategy = Date.ParseStrategy(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: hour)\(minute: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone
        )
        strategy.isLenient = false
        return try? Date(stamp, strategy: strategy)
    }
}
