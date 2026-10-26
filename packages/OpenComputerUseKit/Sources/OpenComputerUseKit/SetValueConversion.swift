import CoreFoundation
import Foundation

/// 仅 CFDate 控件使用严格日期转换；普通文本框保留应用自己的格式与输入语义。
enum SetValueConversion {
    static func dateValueErrorMessage(_ input: String) -> String {
        "set_value on a date control needs a date such as 2026-10-26 or 2026-10-26 10:00 (local time), "
            + "or a time such as 09:30. Invalid or ambiguous local times require correction or an explicit ISO offset; "
            + "\"\(input.prefix(40))\" was not understood. No value was sent."
    }

    static func axValue(
        for input: String, current: CFTypeRef?, timeZone: TimeZone = .current
    ) throws -> CFTypeRef {
        guard let current, CFGetTypeID(current) == CFDateGetTypeID() else { return input as CFString }
        // 已验证 CF 类型；CFDate 与 Date 桥接。
        // swiftlint:disable:next force_cast
        guard let date = parseDate(input, keepingTimeOf: current as! Date, timeZone: timeZone) else {
            throw ComputerUseError.invalidArguments(dateValueErrorMessage(input))
        }
        return date as CFDate
    }

    /// 日期保留原时刻，时间保留原日期；拒绝系统自动归一化的非法日期及 DST 跳时/重复时刻。
    static func parseDate(_ input: String, keepingTimeOf current: Date, timeZone: TimeZone) -> Date? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 固定协议语法；不用系统宽松解析，防止非法日期自动跨月。
        // swiftlint:disable:next line_length
        let pattern = #"^(?:(\d{4})([-/])(\d{2})\2(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2})?)?|(\d{2}):(\d{2})(?::(\d{2}))?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        func number(_ index: Int) -> Int? {
            group(index).flatMap(Int.init)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let previous = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: current)
        let timeOnly = group(1) == nil
        let components = DateComponents(
            year: timeOnly ? previous.year : number(1),
            month: timeOnly ? previous.month : number(3),
            day: timeOnly ? previous.day : number(4),
            hour: timeOnly ? number(10) : number(5) ?? previous.hour,
            minute: timeOnly ? number(11) : number(6) ?? previous.minute,
            second: timeOnly ? number(12) ?? 0 : (group(5) == nil ? previous.second : number(7) ?? 0)
        )
        if let offset = group(9) {
            guard let zone = offsetTimeZone(offset) else { return nil }
            calendar.timeZone = zone
        }
        guard let date = strictDate(components, calendar: calendar) else { return nil }
        return date.addingTimeInterval(group(8).flatMap(Double.init) ?? 0)
    }

    private static func offsetTimeZone(_ offset: String) -> TimeZone? {
        if offset == "Z" { return TimeZone(secondsFromGMT: 0) }
        let parts = offset.dropFirst().split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              hours <= 23, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (offset.first == "-" ? -1 : 1))
    }

    private static func strictDate(_ components: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: components) else { return nil }
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        guard calendar.dateComponents(fields, from: date) == components else { return nil }
        // 同一天内查询两种重复时间策略，避免在秋季 DST 回拨时静默选择其中一次。
        let start = calendar.startOfDay(for: date).addingTimeInterval(-1)
        guard let first = calendar.nextDate(
            after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first
        ),
            let last = calendar.nextDate(
                after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last
            ),
            first == last else { return nil }
        return date
    }
}
