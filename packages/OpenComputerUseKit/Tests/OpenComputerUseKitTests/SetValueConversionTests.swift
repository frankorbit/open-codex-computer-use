@testable import OpenComputerUseKit
import XCTest

final class SetValueConversionTests: XCTestCase {
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!
    // 提醒事项实测：只有日期的日期框，值为本地 0 点（2026-11-25 08:00:00 +0000）。
    private let current = Date(timeIntervalSince1970: 1_795_593_600)

    private func local(_ text: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = pacific
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: (text as NSString).doubleValue))
    }

    private func parsed(_ input: String) -> String? {
        SetValueConversion.parseDate(input, keepingTimeOf: current, timeZone: pacific)
            .map { local(String($0.timeIntervalSince1970)) }
    }

    func testDateOnlyKeepsTheCurrentTimeOfDayAcrossDaylightSaving() {
        XCTAssertEqual(local(String(current.timeIntervalSince1970)), "2026-11-25 00:00:00")
        // 10 月 26 日处于夏令时，仍是本地 0 点，只改日期。
        XCTAssertEqual(parsed("2026-10-26"), "2026-10-26 00:00:00")
        XCTAssertEqual(parsed("2026/10/26"), "2026-10-26 00:00:00")
        XCTAssertEqual(parsed(" 2026-10-26 "), "2026-10-26 00:00:00")
    }

    func testDateAndTimeUseTheGivenLocalTime() {
        XCTAssertEqual(parsed("2026-10-26 10:00"), "2026-10-26 10:00:00")
        XCTAssertEqual(parsed("2026-10-26T10:00"), "2026-10-26 10:00:00")
        XCTAssertEqual(parsed("2026-10-26 10:00:30"), "2026-10-26 10:00:30")
        XCTAssertEqual(parsed("2026/10/26 09:15"), "2026-10-26 09:15:00")
        // 带时区的 ISO 8601 按其时区换算。
        XCTAssertEqual(parsed("2026-10-26T17:00:00Z"), "2026-10-26 10:00:00")
        XCTAssertEqual(parsed("2026-10-26T10:00:00-07:00"), "2026-10-26 10:00:00")
    }

    func testUnparseableOrInvalidDatesAreRejected() {
        for input in ["", "tomorrow", "明天", "10/26/2026", "2026-13-01", "2026-02-30", "2026-10-26 25:00"] {
            XCTAssertNil(parsed(input), input)
        }
    }

    func testOnlyDateValuedTargetsAreConverted() throws {
        let date = try SetValueConversion.axValue(for: "2026-10-26", current: current as CFDate, timeZone: pacific)
        XCTAssertEqual(CFGetTypeID(date), CFDateGetTypeID())
        XCTAssertEqual(local(String((date as! Date).timeIntervalSince1970)), "2026-10-26 00:00:00")
        // 文本框等其他类型照旧写字符串，即使内容看起来像日期。
        for current: CFTypeRef? in ["old text" as CFString, NSNumber(value: 3), nil] {
            let value = try SetValueConversion.axValue(for: "2026-10-26", current: current, timeZone: pacific)
            XCTAssertEqual(value as? String, "2026-10-26")
        }
        XCTAssertThrowsError(try SetValueConversion.axValue(for: "tomorrow", current: current as CFDate, timeZone: pacific)) {
            XCTAssertTrue($0.localizedDescription.contains("2026-10-26 10:00 (local time)"))
            XCTAssertTrue($0.localizedDescription.contains("No value was sent"))
        }
    }
}
