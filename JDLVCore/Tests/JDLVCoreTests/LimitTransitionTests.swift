//
//  LimitTransitionTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/LimitTransitionTest.kt（规格文档 B5）
//  用例数: 16（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.LimitTransition.decide(prevM, prevT, nextM, nextT, countM, countT,
//        running, onlineM, onlineT)（配额迁移决策，S16-03/05）
//        语义：裁剪是本地操作，离线也必须执行；只有"重启引擎"依赖网络。
//
//  参数顺序（位置参数）:
//    decide(prevM, prevT, nextM, nextT, countM, countT, running, onlineM, onlineT)
//    - prev*/next*: 旧/新上限（Int，0=不限）；count*: 当前已扫行数（Int64）
//    - running: 引擎是否在跑；online*: 分库在线标记
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
import Foundation
@testable import JDLVCore

final class LimitTransitionTests: XCTestCase {

    // MARK: - B5. LimitTransitionTest（16 用例）

    /// 变化分支公共断言: reason 非空白且含 "action="（决策原因永远可追溯）
    private func assertChangedReason(
        _ d: LimitDecision, file: StaticString = #filePath, line: UInt = #line
    ) {
        let trimmed = d.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "reason 不能为空白", file: file, line: line)
        XCTAssertTrue(
            d.reason.contains("action="),
            "reason 应含 action=，实际: \(d.reason)", file: file, line: line)
    }

    /// old==new 且 count 未超 → NO_CHANGE；writeMeta/pruneM/pruneT/restart 全 false
    func test_unchangedReturnsNoChange() {
        let d = LimitTransition.decide(50_000, 50_000, 50_000, 50_000, 40_000, 40_000, false, true, true)
        XCTAssertEqual(d.action, .NO_CHANGE)
        XCTAssertFalse(d.writeMeta)
        XCTAssertFalse(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertFalse(d.restart)
        XCTAssertFalse(d.nextDoneM)
        XCTAssertFalse(d.nextDoneT)
        // 同值分支 reason 以 "unchanged prev=..." 开头
        XCTAssertTrue(d.reason.contains("unchanged prev="))
    }

    /// 50000→300000 在线 → RESTART + writeMeta=true + nextDoneM=false（需重扫）
    func test_increaseOnlineRestarts() {
        let d = LimitTransition.decide(50_000, 50_000, 300_000, 50_000, 60_000, 40_000, false, true, true)
        XCTAssertEqual(d.action, .RESTART)
        XCTAssertTrue(d.writeMeta)
        XCTAssertFalse(d.nextDoneM)
        XCTAssertTrue(d.restart)
        XCTAssertFalse(d.pruneM)
        XCTAssertFalse(d.pruneT)
        assertChangedReason(d)
    }

    /// 同上但 M 源离线 → DEFER_OFFLINE；不 restart；writeMeta=true
    func test_increaseOfflineDefers() {
        let d = LimitTransition.decide(50_000, 50_000, 300_000, 50_000, 60_000, 40_000, false, false, true)
        XCTAssertEqual(d.action, .DEFER_OFFLINE)
        XCTAssertTrue(d.writeMeta)
        XCTAssertFalse(d.restart)
        assertChangedReason(d)
    }

    /// 300000→50000（count 300000 > 新上限）在线 → PRUNE_ONLY；pruneM=true；不 restart；nextDoneM=true
    func test_shrinkOnlinePrunesOnly() {
        let d = LimitTransition.decide(300_000, 40_000, 50_000, 40_000, 300_000, 40_000, false, true, true)
        XCTAssertEqual(d.action, .PRUNE_ONLY)
        XCTAssertTrue(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertFalse(d.restart)
        XCTAssertTrue(d.nextDoneM)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)

        // 补充对照: 缩容超限但另一源仍需继续 → 升级为 PRUNE_AND_RESTART（裁剪+重启引擎）
        let both = LimitTransition.decide(300_000, 50_000, 50_000, 50_000, 300_000, 40_000, false, true, true)
        XCTAssertEqual(both.action, .PRUNE_AND_RESTART)
        XCTAssertTrue(both.pruneM)
        XCTAssertTrue(both.restart)
        XCTAssertTrue(both.writeMeta)
        assertChangedReason(both)
    }

    /// 同上离线 → 仍 PRUNE_ONLY（prune 是本地操作不需在线）；不 restart
    func test_shrinkOfflineStillPrunesButDoesNotRestart() {
        let d = LimitTransition.decide(300_000, 40_000, 50_000, 40_000, 300_000, 40_000, false, false, true)
        XCTAssertEqual(d.action, .PRUNE_ONLY)
        XCTAssertTrue(d.pruneM)
        XCTAssertFalse(d.restart)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// old 50000→new 80000，count 60000（<new 但>old）→ RESTART（继续补扫）；不 prune；nextDoneM=false
    func test_shrinkBelowTargetNeedsContinue() {
        let d = LimitTransition.decide(50_000, 60_000, 80_000, 60_000, 60_000, 60_000, false, true, true)
        XCTAssertEqual(d.action, .RESTART)
        XCTAssertFalse(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertFalse(d.nextDoneM)
        XCTAssertTrue(d.restart)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// M/T 同时缩容 → PRUNE_ONLY 且 pruneM、pruneT、nextDoneM、nextDoneT 全 true
    func test_bothChangedBothPrune() {
        let d = LimitTransition.decide(300_000, 300_000, 50_000, 50_000, 300_000, 300_000, false, true, true)
        XCTAssertEqual(d.action, .PRUNE_ONLY)
        XCTAssertTrue(d.pruneM)
        XCTAssertTrue(d.pruneT)
        XCTAssertTrue(d.nextDoneM)
        XCTAssertTrue(d.nextDoneT)
        XCTAssertFalse(d.restart)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// new=0（不限）→ RESTART 继续扫；不 prune；nextDoneM=false
    func test_zeroMeansUnlimitedAndContinues() {
        let d = LimitTransition.decide(50_000, 40_000, 0, 40_000, 60_000, 40_000, false, true, true)
        XCTAssertEqual(d.action, .RESTART)
        XCTAssertFalse(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertFalse(d.nextDoneM)
        XCTAssertTrue(d.restart)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// old 0→new 50000 且 count==50000 → META_ONLY；不 prune；nextDoneM=true
    func test_unlimitedToCappedAtCurrentCountIsMetaOnly() {
        let d = LimitTransition.decide(0, 40_000, 50_000, 40_000, 50_000, 40_000, false, true, true)
        XCTAssertEqual(d.action, .META_ONLY)
        XCTAssertFalse(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertFalse(d.restart)
        XCTAssertTrue(d.nextDoneM)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// count==newCap → META_ONLY；不 prune（恰好达标不算超出）
    func test_countEqualsNextDoesNotPrune() {
        let d = LimitTransition.decide(40_000, 30_000, 50_000, 30_000, 50_000, 30_000, false, true, true)
        XCTAssertEqual(d.action, .META_ONLY)
        XCTAssertFalse(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertTrue(d.nextDoneM)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// M 离线且 M 需要工作（另一源在线）→ DEFER_OFFLINE；不 restart
    func test_oneSourceOfflineWhileOtherNeedsWorkDefers() {
        let d = LimitTransition.decide(100, 50_000, 200, 50_000, 100, 40_000, false, false, true)
        XCTAssertEqual(d.action, .DEFER_OFFLINE)
        XCTAssertFalse(d.restart)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// 仅 T 上限变化 → RESTART；pruneM=false；nextDoneM=true（M 侧不受牵连）
    func test_onlyThreadsChanged() {
        let d = LimitTransition.decide(40_000, 50_000, 40_000, 80_000, 40_000, 60_000, false, true, true)
        XCTAssertEqual(d.action, .RESTART)
        XCTAssertFalse(d.pruneM)
        XCTAssertTrue(d.nextDoneM)
        XCTAssertFalse(d.nextDoneT)
        XCTAssertTrue(d.restart)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }

    /// 全 0（双方均不限）→ NO_CHANGE；不写 meta
    func test_noChangeWhenBothZero() {
        let d = LimitTransition.decide(0, 0, 0, 0, 10_000, 10_000, false, true, true)
        XCTAssertEqual(d.action, .NO_CHANGE)
        XCTAssertFalse(d.writeMeta)
        XCTAssertFalse(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertFalse(d.restart)
        XCTAssertTrue(d.reason.contains("unchanged prev="))
    }

    /// 缩容决策 reason 含 "prune=true"（失败由执行层把 done 改回 0，决策不表达失败）
    func test_pruneFailureIsNotRepresentedInDecision() {
        let d = LimitTransition.decide(300_000, 40_000, 50_000, 40_000, 300_000, 40_000, false, true, true)
        XCTAssertEqual(d.action, .PRUNE_ONLY)
        XCTAssertTrue(d.pruneM)
        XCTAssertTrue(d.reason.contains("prune=true"))
        assertChangedReason(d)
    }

    /// decide(1,2,3,4,5,6,true,true,true) reason 非空白
    func test_reasonIsAlwaysNonBlank() {
        let d = LimitTransition.decide(1, 2, 3, 4, 5, 6, true, true, true)
        let trimmed = d.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertTrue(d.reason.contains("action="))
    }

    /// 缩容且 count 80000 > new 50000 → PRUNE_ONLY + nextDoneM=true
    func test_shrinkAboveCountIsPruneOnly() {
        let d = LimitTransition.decide(60_000, 30_000, 50_000, 30_000, 80_000, 30_000, false, true, true)
        XCTAssertEqual(d.action, .PRUNE_ONLY)
        XCTAssertTrue(d.pruneM)
        XCTAssertFalse(d.pruneT)
        XCTAssertTrue(d.nextDoneM)
        XCTAssertFalse(d.restart)
        XCTAssertTrue(d.writeMeta)
        assertChangedReason(d)
    }
}
