//
//  OfflineGateTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/OfflineGateTest.kt（规格文档 B8）
//  用例数: 7（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.OfflineGate（分库离线软标记 TTL 门，全局静态状态，now 可注入）
//        状态机：在线 = until == 0 或 now >= until；离线 = now < until（严格小于）
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//  注: OfflineGate 是全局静态状态，每个用例 setUp/tearDown 均 reset(now:0)，
//      mark/clear/isOffline 一律显式传 now 注入固定时钟（allOffline 除外——它无 now 参数）。
//

import XCTest
@testable import JDLVCore

final class OfflineGateTests: XCTestCase {

    /// 固定时钟 T0（规格文档 B8 指定）
    private static let T0: Int64 = 1_730_000_000_000

    override func setUp() {
        super.setUp()
        OfflineGate.reset(now: 0)
    }

    override func tearDown() {
        OfflineGate.reset(now: 0)
        super.tearDown()
    }

    // MARK: - B8. OfflineGateTest（7 用例）

    /// mark("jdb", 60000, T0) → T0+59_999 仍判离线
    func test_mark_withinTtl_isOffline() {
        OfflineGate.mark("jdb", ttlMs: 60_000, now: Self.T0)
        XCTAssertTrue(OfflineGate.isOffline("jdb", now: Self.T0 + 59_999))
    }

    /// T0+60_000 与 T0+500_000 → 在线（TTL 到点即失效，含边界：now == until 即在线）
    func test_mark_expired_isOnline() {
        OfflineGate.mark("jdb", ttlMs: 60_000, now: Self.T0)
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: Self.T0 + 60_000))
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: Self.T0 + 500_000))
    }

    /// mark jdb+sht 后 clear("jdb") → jdb 在线、sht 仍离线（分库独立清除）
    func test_clearWhich_onlyClearsOne() {
        OfflineGate.mark("jdb", ttlMs: 60_000, now: Self.T0)
        OfflineGate.mark("sht", ttlMs: 60_000, now: Self.T0)
        OfflineGate.clear("jdb")
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: Self.T0))
        XCTAssertTrue(OfflineGate.isOffline("sht", now: Self.T0))
    }

    /// clear() → 两库均在线；allOffline=false
    func test_clearAll_clearsBoth() {
        OfflineGate.mark("jdb", ttlMs: 60_000, now: Self.T0)
        OfflineGate.mark("sht", ttlMs: 60_000, now: Self.T0)
        OfflineGate.clear()
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: Self.T0))
        XCTAssertFalse(OfflineGate.isOffline("sht", now: Self.T0))
        XCTAssertFalse(OfflineGate.allOffline)
    }

    /// 仅 mark sht（真实时钟，与 Android 用例一致）→ allOffline=true（任一库离线即 true）
    func test_allOffline_trueWhenAnyOffline() {
        OfflineGate.mark("sht", ttlMs: 60_000)  // 不传 now → 用真实时钟 nowMs()
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: Self.T0))  // jdb 从未标记 → 在线
        XCTAssertTrue(OfflineGate.allOffline)
    }

    /// jdb TTL 10s、sht TTL 60s → T0+10_001 时 jdb 在线、sht 离线（各库独立计时）
    func test_independentTimers() {
        OfflineGate.mark("jdb", ttlMs: 10_000, now: Self.T0)
        OfflineGate.mark("sht", ttlMs: 60_000, now: Self.T0)
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: Self.T0 + 10_001))
        XCTAssertTrue(OfflineGate.isOffline("sht", now: Self.T0 + 10_001))
    }

    /// 未标记 → isOffline("jdb"/"sht") 均 false
    func test_noMark_isOnline() {
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: Self.T0))
        XCTAssertFalse(OfflineGate.isOffline("sht", now: Self.T0))
    }
}
