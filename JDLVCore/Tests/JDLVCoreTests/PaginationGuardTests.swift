//
//  PaginationGuardTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/PaginationGuardTest.kt（规格文档 B9）
//  用例数: 15（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.PaginationGuard.clamp(requested:total:per:hardOffset:) → PageDecision
//        （total 参数为 Int64；hardOffset 默认 5000 行；reason 中文原文逐字比对）
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class PaginationGuardTests: XCTestCase {

    // MARK: - B9. PaginationGuardTest（15 用例）

    /// clamp(0,0,40) → page=1, clamped=true
    func test_requestedZeroBecomesOne() {
        let d = PaginationGuard.clamp(requested: 0, total: 0, per: 40)
        XCTAssertEqual(d.page, 1)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "总数未知，深翻页上限约 125 页")
    }

    /// clamp(1,0,40) → page=1, clamped=false（1 永远合法）
    func test_requestedOneNotClamped() {
        let d = PaginationGuard.clamp(requested: 1, total: 0, per: 40)
        XCTAssertEqual(d.page, 1)
        XCTAssertFalse(d.clamped)
        XCTAssertEqual(d.reason, "")
    }

    /// clamp(2,1,40) → page=1, clamped=true（total=1 只有 1 页）
    func test_totalOneAllowsOnePage() {
        let d = PaginationGuard.clamp(requested: 2, total: 1, per: 40)
        XCTAssertEqual(d.page, 1)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "深翻页上限约 1 页（OFFSET≤5000）")
    }

    /// clamp(9999,5000,40) → 125, clamped（5000/40=125 页）
    func test_totalFiveThousandPer40() {
        let d = PaginationGuard.clamp(requested: 9999, total: 5000, per: 40)
        XCTAssertEqual(d.page, 125)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "深翻页上限约 125 页（OFFSET≤5000）")
    }

    /// clamp(9999,5000,60) → 83, clamped
    func test_totalFiveThousandPer60() {
        let d = PaginationGuard.clamp(requested: 9999, total: 5000, per: 60)
        XCTAssertEqual(d.page, 83)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "深翻页上限约 83 页（OFFSET≤5000）")
    }

    /// clamp(999_999,1_000_000,40) → 125, clamped
    /// （硬 OFFSET 上限 5000 行优先于已知 total：100 万行也只能翻 125 页）
    func test_oneMillionPer40LastPage() {
        let d = PaginationGuard.clamp(requested: 999_999, total: 1_000_000, per: 40)
        XCTAssertEqual(d.page, 125)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "深翻页上限约 125 页（OFFSET≤5000）")
    }

    /// clamp(9999,0,40) → 125（total 未知按硬上限）
    func test_unknownTotalPer40Caps125() {
        let d = PaginationGuard.clamp(requested: 9999, total: 0, per: 40)
        XCTAssertEqual(d.page, 125)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "总数未知，深翻页上限约 125 页")
    }

    /// clamp(9999,0,60) → 83
    func test_unknownTotalPer60Caps83() {
        let d = PaginationGuard.clamp(requested: 9999, total: 0, per: 60)
        XCTAssertEqual(d.page, 83)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "总数未知，深翻页上限约 83 页")
    }

    /// clamp(125,0,40) → 125, not clamped（恰在硬边界允许）
    func test_unknownTotalPage125Allowed() {
        let d = PaginationGuard.clamp(requested: 125, total: 0, per: 40)
        XCTAssertEqual(d.page, 125)
        XCTAssertFalse(d.clamped)
        XCTAssertEqual(d.reason, "")
    }

    /// clamp(126,0,40) → 125, clamped
    func test_unknownTotalPage126Clamped() {
        let d = PaginationGuard.clamp(requested: 126, total: 0, per: 40)
        XCTAssertEqual(d.page, 125)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "总数未知，深翻页上限约 125 页")
    }

    /// clamp(125,5000,40) → 125, not clamped（known total 的末页恰在硬限内）
    func test_knownTotalExactBoundaryNotClamped() {
        let d = PaginationGuard.clamp(requested: 125, total: 5000, per: 40)
        XCTAssertEqual(d.page, 125)
        XCTAssertFalse(d.clamped)
        XCTAssertEqual(d.reason, "")
    }

    /// clamp(-3,5000,40) → 1, clamped
    func test_negativeRequestedBecomesOne() {
        let d = PaginationGuard.clamp(requested: -3, total: 5000, per: 40)
        XCTAssertEqual(d.page, 1)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "深翻页上限约 125 页（OFFSET≤5000）")
    }

    /// clamp(9,1,0).page==1（per=0 按 1 处理防除零）
    func test_zeroPerTreatedAsOne() {
        let d = PaginationGuard.clamp(requested: 9, total: 1, per: 0)
        XCTAssertEqual(d.page, 1)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "深翻页上限约 1 页（OFFSET≤5000）")
    }

    /// clamp(9999,-1,40,hardOffset=2000) → 50, clamped（2000/40=50；total=-1 视未知）
    func test_customHardOffset() {
        let d = PaginationGuard.clamp(requested: 9999, total: -1, per: 40, hardOffset: 2000)
        XCTAssertEqual(d.page, 50)
        XCTAssertTrue(d.clamped)
        XCTAssertEqual(d.reason, "总数未知，深翻页上限约 50 页")
    }

    /// clamp(9999,0,40).reason 含 "125"（提示文案带具体页数）
    func test_reasonMentionsLimit() {
        let d = PaginationGuard.clamp(requested: 9999, total: 0, per: 40)
        XCTAssertTrue(d.reason.contains("125"))
        XCTAssertEqual(d.reason, "总数未知，深翻页上限约 125 页")
    }
}
