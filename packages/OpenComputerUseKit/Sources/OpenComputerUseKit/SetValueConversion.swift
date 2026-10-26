import CoreFoundation
import Foundation

/// set_value 的字符串参数按目标当前值的类型转换。日期控件（提醒事项、日历的日期框）的 AXValue 是 CFDate，
/// 直接写字符串会被以 -25201（非法参数）拒绝；后台点击又不能让弹层里的日期框获得键盘焦点。所以当前值是
/// 日期时，按本地时区解析常见日期写法并写入 CFDate。其他类型保持原样写字符串。
enum SetValueConversion {
    static let dateFormats = [
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
    ]

    static func dateValueErrorMessage(_ input: String) -> String {
        "set_value on a date control needs a date such as 2026-10-26 or 2026-10-26 10:00 (local time); "
            + "\"\(input.prefix(40))\" was not understood. No value was sent."
    }

    /// 返回要写入 AXValue 的值：当前值是日期时为 CFDate，否则为原字符串。
    static func axValue(
        for input: String, current: CFTypeRef?, timeZone: TimeZone = .current
    ) throws -> CFTypeRef {
        guard let current, CFGetTypeID(current) == CFDateGetTypeID() else { return input as CFString }
        guard let date = parseDate(input, keepingTimeOf: current as! Date, timeZone: timeZone) else {
            throw ComputerUseError.invalidArguments(dateValueErrorMessage(input))
        }
        return date as CFDate
    }

    /// 带时区的 ISO 8601 按其时区；其余按本地时区。只有日期时保留原值在本地时区的时刻（只改日期）。
    static func parseDate(_ input: String, keepingTimeOf current: Date, timeZone: TimeZone) -> Date? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        for format in dateFormats {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: text) else { continue }
            guard !format.contains("HH") else { return parsed }
            let day = calendar.dateComponents([.year, .month, .day], from: parsed)
            let time = calendar.dateComponents([.hour, .minute, .second], from: current)
            return calendar.date(from: DateComponents(
                year: day.year, month: day.month, day: day.day,
                hour: time.hour, minute: time.minute, second: time.second
            ))
        }
        return nil
    }
}
