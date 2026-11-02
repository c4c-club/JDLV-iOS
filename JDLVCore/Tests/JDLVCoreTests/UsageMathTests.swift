//
//  UsageMathTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/UsageMathTest.kt（规格文档 B15）
//  用例数: 4（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.UsageMath.total(_:_:) = max(0, mainBytes) + max(0, walBytes)（负值钳 0）
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class UsageMathTests: XCTestCase {

    // MARK: - B15. UsageMathTest（4 用例）

    /// total(1000, 200) == 1200
    func test_addsWal() {
        XCTAssertEqual(UsageMath.total(1000, 200), 1200)
    }

    /// total(1000, 0) == 1000
    func test_zeroWal() {
        XCTAssertEqual(UsageMath.total(1000, 0), 1000)
    }

    /// total(1000, -5) == 1000（负 WAL 视 0）
    func test_negativeWalIgnored() {
        XCTAssertEqual(UsageMath.total(1000, -5), 1000)
    }

    /// total(-1, 200) == 200（负 main 视 0）
    func test_negativeMainIgnored() {
        XCTAssertEqual(UsageMath.total(-1, 200), 200)
    }
}
