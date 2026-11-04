import Foundation

/// A calendar date without time or time zone (e.g. a task start day).
///
/// Stored as `yyyy-MM-dd` in SQLite and maps to Postgres `date`. Day arithmetic uses
/// a proleptic Gregorian day count, so DST changes and device time zones never shift
/// a planned day. Convert to/from `Date` only at the UI edge (`DatePicker`).
struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1,
              day <= Self.daysInMonth(year: year, month: month)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Days since 1970-01-01 (may be negative).
    init(ordinal: Int) {
        let (y, m, d) = Self.civil(fromDays: ordinal)
        self.year = y
        self.month = m
        self.day = d
    }

    /// Parses `yyyy-MM-dd` strictly.
    init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The day shown on the wall calendar for `date` in `calendar`'s time zone.
    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(ordinal: Self.days(fromCivil: c.year ?? 1970, c.month ?? 1, c.day ?? 1))
    }

    static func today(calendar: Calendar = .current) -> CalendarDay {
        CalendarDay(Date(), calendar: calendar)
    }

    var ordinal: Int { Self.days(fromCivil: year, month, day) }

    var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { isoString }

    /// Local noon on this day — safe for `DatePicker` round trips across DST.
    func date(calendar: Calendar = .current) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = 12
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: TimeInterval(ordinal) * 86_400)
    }

    func adding(days: Int) -> CalendarDay {
        CalendarDay(ordinal: ordinal + days)
    }

    /// Signed number of days from `self` to `other`.
    func days(to other: CalendarDay) -> Int {
        other.ordinal - ordinal
    }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    var isoWeekday: Int {
        // 1970-01-01 was a Thursday.
        ((ordinal % 7) + 7 + 3) % 7 + 1
    }

    var isWeekend: Bool { isoWeekday >= 6 }

    var startOfWeek: CalendarDay { adding(days: 1 - isoWeekday) }

    var startOfMonth: CalendarDay { CalendarDay(year: year, month: month, day: 1)! }

    var daysInMonth: Int { Self.daysInMonth(year: year, month: month) }

    var startOfNextMonth: CalendarDay { startOfMonth.adding(days: daysInMonth) }

    /// ISO-8601 week number (1…53).
    var isoWeekOfYear: Int {
        let thursday = adding(days: 4 - isoWeekday)
        let jan1 = CalendarDay(year: thursday.year, month: 1, day: 1)!
        return jan1.days(to: thursday) / 7 + 1
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        default: return 0
        }
    }

    // Howard Hinnant's civil-from-days / days-from-civil algorithms.

    private static func days(fromCivil year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

extension CalendarDay: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CalendarDay(isoString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected yyyy-MM-dd, got \(raw)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}
