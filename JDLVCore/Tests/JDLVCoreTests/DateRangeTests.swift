//
//  DateRangeTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/DateRangeTest.kt（规格文档 B2）
//  用例数: 10（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.DateRange.monthRange(_:_:) → [yyyy-MM-01, 次月 01) 半开区间字符串对
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class DateRangeTests: XCTestCase {

    /// 断言 monthRange 返回 (start, end)；nil 或不等时失败并指向调用处
    private func assertRange(
        _ actual: (String, String)?,
        _ start: String,
        _ end: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("期望区间 (\(start), \(end))，实际为 nil", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.0, start, file: file, line: line)
        XCTAssertEqual(actual.1, end, file: file, line: line)
    }

    // MARK: - B2. DateRangeTest（10 用例）

    /// ("2024","1") == ("2024-01-01","2024-02-01")
    func test_january() {
        assertRange(DateRange.monthRange("2024", "1"), "2024-01-01", "2024-02-01")
    }

    /// ("2024","8") == ("2024-08-01","2024-09-01")
    func test_august() {
        assertRange(DateRange.monthRange("2024", "8"), "2024-08-01", "2024-09-01")
    }

    /// ("2024","09") 与 ("2024","9") 同为 ("2024-09-01","2024-10-01")（前导零无关）
    func test_septemberBoundaryIsSevenChars() {
        assertRange(DateRange.monthRange("2024", "09"), "2024-09-01", "2024-10-01")
        assertRange(DateRange.monthRange("2024", "9"), "2024-09-01", "2024-10-01")
    }

    /// ("2024","12") == ("2024-12-01","2025-01-01")（跨年）
    func test_decemberRollsToNextYear() {
        assertRange(DateRange.monthRange("2024", "12"), "2024-12-01", "2025-01-01")
    }

    /// ("2024","2") == ("2024-02-01","2024-03-01")（闰年 2 月仍按月首/次月首）
    func test_leapFebruary() {
        assertRange(DateRange.monthRange("2024", "2"), "2024-02-01", "2024-03-01")
    }

    /// ("2023","2") == ("2023-02-01","2023-03-01")
    func test_nonLeapFebruary() {
        assertRange(DateRange.monthRange("2023", "2"), "2023-02-01", "2023-03-01")
    }

    /// ("24"/"20245"/"abcd","1") → nil（年份必须恰 4 位数字）
    func test_invalidYear() {
        XCTAssertNil(DateRange.monthRange("24", "1"))
        XCTAssertNil(DateRange.monthRange("20245", "1"))
        XCTAssertNil(DateRange.monthRange("abcd", "1"))
    }

    /// ("2024","0"/"13"/"x"/"") → nil
    func test_invalidMonth() {
        XCTAssertNil(DateRange.monthRange("2024", "0"))
        XCTAssertNil(DateRange.monthRange("2024", "13"))
        XCTAssertNil(DateRange.monthRange("2024", "x"))
        XCTAssertNil(DateRange.monthRange("2024", ""))
    }

    /// (" 2024 "," 1 ") → 正常区间（先 trim）
    func test_trimsWhitespace() {
        assertRange(DateRange.monthRange(" 2024 ", " 1 "), "2024-01-01", "2024-02-01")
    }

    /// ("2024","11") → ("2024-11-01","2024-12-01")（上界=次月 1 日，半开）
    func test_upperBoundStrictlyGreaterThanStart() {
        let range = DateRange.monthRange("2024", "11")
        assertRange(range, "2024-11-01", "2024-12-01")
        if let range {
            XCTAssertTrue(range.0 < range.1, "上界必须严格大于下界（半开区间）")
        }
    }

    // MARK: - R4 P7：Unicode 数字 / 非法年份不崩溃（V40）

    /// 全角「２０２６」：isNumber 为 true 但 Int() 只认 ASCII → nil（原 Int(y)! 崩溃点）
    func test_fullwidthDigitsReturnNil() {
        XCTAssertNil(DateRange.monthRange("２０２６", "1"))
    }

    /// 阿拉伯-印度数字「٢٠٢٦」：同理 nil
    func test_arabicIndicDigitsReturnNil() {
        XCTAssertNil(DateRange.monthRange("٢٠٢٦", "1"))
    }

    /// 混入字母后缀 "202a"：isNumber 过滤 → nil
    func test_alphaSuffixReturnsNil() {
        XCTAssertNil(DateRange.monthRange("202a", "1"))
    }

    /// "0000"：年份有效域 1...9999 → nil（"0099" = 99 年，合法非 nil）
    func test_yearZeroReturnsNil() {
        XCTAssertNil(DateRange.monthRange("0000", "1"))
        XCTAssertNotNil(DateRange.monthRange("0099", "1"))
    }
}
