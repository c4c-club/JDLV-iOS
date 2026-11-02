//
//  RefreshPolicyTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/RefreshPolicyTest.kt（规格文档 B11）
//  用例数: 6（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.RefreshPolicy.shouldAuto(lastAt:now:)（自动刷新 60s 冷却）
//        语义：lastAt==0（从未自动刷新过）或距上次 >= 冷却期 → 允许
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class RefreshPolicyTests: XCTestCase {

    // MARK: - B11. RefreshPolicyTest（6 用例）

    /// lastAt=0（从未自动刷）→ true
    func test_neverAutoRefreshed_allows() {
        XCTAssertTrue(RefreshPolicy.shouldAuto(0, now: 1_000))
    }

    /// 间隔 59_999ms → false
    func test_withinCooldown_blocks() {
        let lastAt: Int64 = 1_000_000
        XCTAssertFalse(RefreshPolicy.shouldAuto(lastAt, now: lastAt + 59_999))
    }

    /// 恰 60_000ms → true（边界放行）
    func test_atCooldownBoundary_allows() {
        let lastAt: Int64 = 1_000_000
        XCTAssertTrue(RefreshPolicy.shouldAuto(lastAt, now: lastAt + 60_000))
    }

    /// 61_000ms → true
    func test_beyondCooldown_allows() {
        let lastAt: Int64 = 1_000_000
        XCTAssertTrue(RefreshPolicy.shouldAuto(lastAt, now: lastAt + 61_000))
    }

    /// now<lastAt（时钟回拨，负间隔）→ false（与实现一致的保守行为）
    func test_negativeInterval_blocked() {
        XCTAssertFalse(RefreshPolicy.shouldAuto(2_000_000, now: 1_000_000))
    }

    /// AUTO_COOLDOWN_MS == 60_000L
    func test_constantIsSixtySeconds() {
        XCTAssertEqual(RefreshPolicy.AUTO_COOLDOWN_MS, 60_000)
    }
}
