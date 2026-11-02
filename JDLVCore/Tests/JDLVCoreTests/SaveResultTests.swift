//
//  SaveResultTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/SaveResultTest.kt（规格文档 B12）
//  用例数: 6（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.SaveResult（设置保存三态枚举；NO_CHANGE 不是失败，改回原值不显示红字）
//        Android 的 valueOf/ordinal 断言在 Swift 侧等价映射为 named(...) 与 rawValue（0/1/2 顺序锁定）
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class SaveResultTests: XCTestCase {

    // MARK: - B12. SaveResultTest（6 用例）

    /// 枚举恰 3 个值
    func test_threeStates() {
        XCTAssertEqual(SaveResult.allCases.count, 3)
    }

    /// valueOf("SAVED") == SAVED
    func test_savedExists() {
        XCTAssertEqual(SaveResult.named("SAVED"), .saved)
    }

    /// valueOf("NO_CHANGE") == NO_CHANGE
    func test_noChangeExists() {
        XCTAssertEqual(SaveResult.named("NO_CHANGE"), .noChange)
    }

    /// valueOf("FAILED") == FAILED
    func test_failedExists() {
        XCTAssertEqual(SaveResult.named("FAILED"), .failed)
    }

    /// NO_CHANGE != FAILED（核心语义：无变化不显示红字）
    func test_noChangeIsNotFailure() {
        XCTAssertNotEqual(SaveResult.noChange, SaveResult.failed)
    }

    /// SAVED.ordinal < NO_CHANGE.ordinal < FAILED.ordinal（顺序锁定；Swift 用 rawValue 等价断言）
    func test_ordinalOrderIsStable() {
        XCTAssertLessThan(SaveResult.saved.rawValue, SaveResult.noChange.rawValue)
        XCTAssertLessThan(SaveResult.noChange.rawValue, SaveResult.failed.rawValue)
    }
}
