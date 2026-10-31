import Foundation

/// Run and slot arithmetic. A run is the nominal DWD composite time (5-minute grid, UTC).
public enum TimeUtil {
    public static let step: TimeInterval = 300
    public static let horizonMinutes = 120
    /// Analysis + 24 forecast steps = 25.
    public static let forecastSlots = horizonMinutes / 5 + 1
    /// Past analyses referenced from earlier runs.
    public static let historySlots = 12

    private static func components(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private static func pad(_ value: Int?, _ width: Int = 2) -> String {
        let text = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    public static func floorStep(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    /// Floors a date to a multiple of `interval` seconds since the epoch (UTC grid).
    public static func floor(_ date: Date, to interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / interval).rounded(.down) * interval)
    }

    public static func year(of date: Date) -> Int { components(date).year ?? 0 }

    /// `20261030T1105Z`
    public static func toID(_ date: Date) -> String {
        let c = components(date)
        return "\(pad(c.year, 4))\(pad(c.month))\(pad(c.day))T\(pad(c.hour))\(pad(c.minute))Z"
    }

    public static func fromID(_ id: String) -> Date? {
        let b = Array(id.utf8)
        guard b.count == 14, b[8] == 0x54, b[13] == 0x5A else { return nil }
        func num(_ range: Range<Int>) -> Int? { Int(String(decoding: b[range], as: UTF8.self)) }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8), let h = num(9..<11), let mi = num(11..<13)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))
    }

    /// WMS time with milliseconds; the DWD answers without them with an XML error.
    public static func toWMS(_ date: Date) -> String {
        let c = components(date)
        return "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day))T\(pad(c.hour)):\(pad(c.minute)):00.000Z"
    }

    public static func toISO(_ date: Date) -> String {
        let c = components(date)
        return "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day))T\(pad(c.hour)):\(pad(c.minute)):\(pad(c.second))Z"
    }

    /// `2026-10-30 11:05:00` (naive UTC, as stored in DATETIME columns).
    public static func toSQL(_ date: Date) -> String {
        let c = components(date)
        return "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day)) \(pad(c.hour)):\(pad(c.minute)):\(pad(c.second))"
    }

    /// Parses `2026-10-30 11:05:00` or `2026-10-30T11:05:00Z`.
    public static func fromSQL(_ text: String) -> Date? {
        let digits = text.unicodeScalars.filter { $0.properties.numericType != nil }.map { Int($0.value) - 48 }
        guard digits.count >= 14 else { return nil }
        func n(_ r: Range<Int>) -> Int { digits[r].reduce(0) { $0 * 10 + $1 } }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: n(0..<4), month: n(4..<6), day: n(6..<8), hour: n(8..<10), minute: n(10..<12), second: n(12..<14)))
    }

    /// Newest run that should already be available (DWD publishes about 3-3.5 minutes after nominal).
    public static func latestRun(now: Date, availabilityDelay: TimeInterval) -> Date {
        floorStep(now.addingTimeInterval(-availabilityDelay))
    }

    public static func slots(of run: Date) -> [Date] {
        (0..<forecastSlots).map { run.addingTimeInterval(Double($0) * step) }
    }

    /// Next moment at which a new run should be available.
    public static func nextWakeup(now: Date, availabilityDelay: TimeInterval) -> Date {
        floorStep(now.addingTimeInterval(-availabilityDelay)).addingTimeInterval(step + availabilityDelay)
    }
}
