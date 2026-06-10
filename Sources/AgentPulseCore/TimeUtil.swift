import Foundation

/// Date helpers. All "day" strings are `yyyy-MM-dd` in the user's local time zone.
public enum TimeUtil {
    /// Local-time day formatter (yyyy-MM-dd).
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func day(fromISO s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        let date = isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
        guard let date else { return nil }
        return dayFormatter.string(from: date)
    }

    public static func day(fromEpoch t: Double) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: t))
    }

    public static func day(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    public static func date(fromDay day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    /// Parse an ISO-8601 timestamp (with or without fractional seconds) from an `Any` value.
    public static func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
    }

    public static func today() -> String { day(from: Date()) }

    /// Inclusive list of day strings between `start` and `end`.
    public static func dayRange(start: Date, end: Date) -> [String] {
        var out: [String] = []
        let cal = Calendar.current
        var cur = cal.startOfDay(for: start)
        let last = cal.startOfDay(for: end)
        while cur <= last {
            out.append(dayFormatter.string(from: cur))
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }
}

/// A selectable reporting period.
public enum Period: Equatable, Sendable {
    case week                 // last 7 days incl. today
    case month                // last 30 days incl. today
    case custom(Date, Date)   // explicit start...end

    public func bounds(now: Date = Date()) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: now)
        switch self {
        case .week:
            return (cal.date(byAdding: .day, value: -6, to: endDay)!, now)
        case .month:
            return (cal.date(byAdding: .day, value: -29, to: endDay)!, now)
        case .custom(let s, let e):
            return (min(s, e), max(s, e))
        }
    }

    public func dayBounds(now: Date = Date()) -> (start: String, end: String) {
        let (s, e) = bounds(now: now)
        return (TimeUtil.day(from: s), TimeUtil.day(from: e))
    }
}
