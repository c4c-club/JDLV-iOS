//
//  LimitMathTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/LimitMathTest.kt（规格文档 B4）
//  用例数: 7（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.LimitMath（落盘归一 / 运行时 target / 万与条解析 / 中文格式化 / 合法性）
//        UNLIMITED_MARK 为 Int32；parseWan/parseCount 返回 Int64?；format 中文文案逐字比对
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class LimitMathTests: XCTestCase {

    // MARK: - B4. LimitMathTest（7 用例）

    /// normalizeStored(0/1/9999/10000/125000) 各自不变
    func test_normalizeStored_zeroAndSmall() {
        XCTAssertEqual(LimitMath.normalizeStored(0), 0)
        XCTAssertEqual(LimitMath.normalizeStored(1), 1)
        XCTAssertEqual(LimitMath.normalizeStored(9_999), 9_999)
        XCTAssertEqual(LimitMath.normalizeStored(10_000), 10_000)
        XCTAssertEqual(LimitMath.normalizeStored(125_000), 125_000)
    }

    /// UNLIMITED_MARK、Int.MAX_VALUE、Int.MAX_VALUE/2+1 → 0（"不限"标记坍缩为 0）
    func test_normalizeStored_unlimitedMarkCollapsesToZero() {
        XCTAssertEqual(LimitMath.normalizeStored(Int(LimitMath.UNLIMITED_MARK)), 0)
        XCTAssertEqual(LimitMath.normalizeStored(Int.max), 0)
        XCTAssertEqual(LimitMath.normalizeStored(Int.max / 2 + 1), 0)
    }

    /// targetOf(0)==targetOf(-5)==Long.MAX_VALUE/2；targetOf(240000)==240000；targetOf(1)==1
    func test_targetOf_zeroMeansUnlimited() {
        let unlimited = Int64.max / 2  // 等价 Kotlin Long.MAX_VALUE / 2
        XCTAssertEqual(LimitMath.targetOf(0), unlimited)
        XCTAssertEqual(LimitMath.targetOf(-5), unlimited)
        XCTAssertEqual(LimitMath.targetOf(240_000), 240_000)
        XCTAssertEqual(LimitMath.targetOf(1), 1)
    }

    /// "24"→240000；"12.5"→125000；"0"→0；""/"abc"/"-1"/"NaN"→null
    func test_parseWan_supportsDecimalAndRejectsGarbage() {
        XCTAssertEqual(LimitMath.parseWan("24"), 240_000)
        XCTAssertEqual(LimitMath.parseWan("12.5"), 125_000)
        XCTAssertEqual(LimitMath.parseWan("0"), 0)
        XCTAssertNil(LimitMath.parseWan(""))
        XCTAssertNil(LimitMath.parseWan("abc"))
        XCTAssertNil(LimitMath.parseWan("-1"))
        XCTAssertNil(LimitMath.parseWan("NaN"))
    }

    /// "150000"→150000；"0"→0；"12.5"/"-3"/""→null（仅纯整数）
    func test_parseCount_plainIntegerOnly() {
        XCTAssertEqual(LimitMath.parseCount("150000"), 150_000)
        XCTAssertEqual(LimitMath.parseCount("0"), 0)
        XCTAssertNil(LimitMath.parseCount("12.5"))
        XCTAssertNil(LimitMath.parseCount("-3"))
        XCTAssertNil(LimitMath.parseCount(""))
    }

    /// format(0/-1)=="不限"；240000→"24 万 (240,000)"；125000→"12.5 万 (125,000)"；
    /// 150000→"15 万 (150,000)"；9999→"9,999 条"；1→"1 条"（<1 万用"条"）
    func test_format_matchesLegacyWording() {
        XCTAssertEqual(LimitMath.format(0), "不限")
        XCTAssertEqual(LimitMath.format(-1), "不限")
        XCTAssertEqual(LimitMath.format(240_000), "24 万 (240,000)")
        XCTAssertEqual(LimitMath.format(125_000), "12.5 万 (125,000)")
        XCTAssertEqual(LimitMath.format(150_000), "15 万 (150,000)")
        XCTAssertEqual(LimitMath.format(9_999), "9,999 条")
        XCTAssertEqual(LimitMath.format(1), "1 条")
    }

    /// 0 与 5,000,000 合法；5,000,001、null、-1 非法
    func test_isValid_bounds() {
        XCTAssertTrue(LimitMath.isValid(0))
        XCTAssertTrue(LimitMath.isValid(5_000_000))
        XCTAssertFalse(LimitMath.isValid(5_000_001))
        XCTAssertFalse(LimitMath.isValid(nil))
        XCTAssertFalse(LimitMath.isValid(-1))
    }
}
