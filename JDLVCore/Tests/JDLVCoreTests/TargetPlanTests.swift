//
//  TargetPlanTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/TargetPlanTest.kt（规格文档 B14）
//  用例数: 18（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.TargetPlanPolicy.plan(target:total:done:exhausted:) 与
//        moreWork(limM:limT:cntM:cntT:doneM:doneT:onlineM:onlineT:rowsThisRun:)
//        （预热目标计划/巡检续跑决策，纯决策无 IO）
//        语义：target<=0 = 不限（内部 0 表示）；done=true 表示"当前目标已满足"；
//              exhausted=true 表示源库已扫完；shouldPrune = 目标有限且当前行数超过目标；
//              moreWork 的 rowsThisRun<=0 恒 false（无进展不空转）。
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class TargetPlanTests: XCTestCase {

    // MARK: - B14. TargetPlanTest（18 用例）

    // MARK: plan(target:total:done:exhausted:)

    /// plan(0, 100_000) → target==0、continueScan=true、shouldPrune=false、resetCursorToBoundary=false（不限额永不裁剪）
    func test_unlimitedNeverPrunes() {
        let p = TargetPlanPolicy.plan(target: 0, total: 100_000, done: false, exhausted: false)
        XCTAssertEqual(p.target, 0)
        XCTAssertEqual(p.total, 100_000)
        XCTAssertFalse(p.done)
        XCTAssertTrue(p.continueScan)
        XCTAssertFalse(p.shouldPrune)
        XCTAssertFalse(p.resetCursorToBoundary)
    }

    /// plan(50_000, 49_000) → continueScan=true、done=false、shouldPrune=false
    func test_belowTargetContinues() {
        let p = TargetPlanPolicy.plan(target: 50_000, total: 49_000, done: false, exhausted: false)
        XCTAssertEqual(p.target, 50_000)
        XCTAssertTrue(p.continueScan)
        XCTAssertFalse(p.done)
        XCTAssertFalse(p.shouldPrune)
        XCTAssertFalse(p.resetCursorToBoundary)
    }

    /// plan(50_000, 50_000) → done=true、不 continue、不 prune（恰好达标不裁剪）
    func test_exactlyAtTargetFinishesWithoutPrune() {
        let p = TargetPlanPolicy.plan(target: 50_000, total: 50_000, done: false, exhausted: false)
        XCTAssertTrue(p.done)
        XCTAssertFalse(p.continueScan)
        XCTAssertFalse(p.shouldPrune)
        XCTAssertFalse(p.resetCursorToBoundary)
    }

    /// plan(50_000, 60_000) → done+shouldPrune+resetCursorToBoundary 全 true
    func test_aboveTargetPrunesAndResets() {
        let p = TargetPlanPolicy.plan(target: 50_000, total: 60_000, done: false, exhausted: false)
        XCTAssertTrue(p.done)
        XCTAssertFalse(p.continueScan)
        XCTAssertTrue(p.shouldPrune)
        XCTAssertTrue(p.resetCursorToBoundary)
    }

    /// plan(50_000, 60_000, done=true) → 仍 shouldPrune+resetCursor（done 标志不免除超限裁剪）
    func test_aboveTargetEvenWhenDoneFlag() {
        let p = TargetPlanPolicy.plan(target: 50_000, total: 60_000, done: true, exhausted: false)
        XCTAssertTrue(p.done)
        XCTAssertTrue(p.shouldPrune)
        XCTAssertTrue(p.resetCursorToBoundary)
        XCTAssertFalse(p.continueScan)
    }

    /// plan(80_000, 60_000, exhausted=true) → done=true、continueScan=false（源库扫完即收工）
    func test_exhaustedFinishes() {
        let p = TargetPlanPolicy.plan(target: 80_000, total: 60_000, done: false, exhausted: true)
        XCTAssertTrue(p.done)
        XCTAssertFalse(p.continueScan)
        XCTAssertFalse(p.shouldPrune)
        XCTAssertFalse(p.resetCursorToBoundary)
    }

    /// plan(50_000, 0) → continueScan=true（空索引继续扫）
    func test_emptyIndexContinues() {
        let p = TargetPlanPolicy.plan(target: 50_000, total: 0, done: false, exhausted: false)
        XCTAssertTrue(p.continueScan)
        XCTAssertFalse(p.done)
        XCTAssertFalse(p.shouldPrune)
        XCTAssertFalse(p.resetCursorToBoundary)
    }

    /// plan(50_000, 10_000, done=true) → done=true、continueScan=false（done 优先于未达标）
    func test_doneFlagWins() {
        let p = TargetPlanPolicy.plan(target: 50_000, total: 10_000, done: true, exhausted: false)
        XCTAssertTrue(p.done)
        XCTAssertFalse(p.continueScan)
        XCTAssertFalse(p.shouldPrune)
        XCTAssertFalse(p.resetCursorToBoundary)
    }

    /// plan(80_000, 1) → target==80000L、total==1L（Long 类型精确保存）
    func test_targetStoredAsLong() {
        let p = TargetPlanPolicy.plan(target: 80_000, total: 1, done: false, exhausted: false)
        XCTAssertEqual(p.target, 80_000)
        XCTAssertEqual(p.total, 1)
        XCTAssertTrue(p.continueScan) // 1 < 80_000，未达标继续扫
    }

    // MARK: moreWork(limM:limT:cntM:cntT:doneM:doneT:onlineM:onlineT:rowsThisRun:)

    /// rows=0 + 双源 done → false
    func test_noWorkWhenDoneAndNoRows() {
        XCTAssertFalse(TargetPlanPolicy.moreWork(
            limM: 50_000, limT: 50_000, cntM: 10_000, cntT: 10_000,
            doneM: true, doneT: true, onlineM: true, onlineT: true, rowsThisRun: 0))
    }

    /// 前后行数相同 (10→10) → false（无进展不空转，rowsThisRun=0 恒 false）
    func test_noWorkWhenNoProgress() {
        XCTAssertFalse(TargetPlanPolicy.moreWork(
            limM: 50_000, limT: 50_000, cntM: 10, cntT: 10,
            doneM: false, doneT: false, onlineM: true, onlineT: true, rowsThisRun: 0))
    }

    /// 双源均离线 → false（续跑依赖至少一源在线）
    func test_noWorkWhenSourcesOffline() {
        XCTAssertFalse(TargetPlanPolicy.moreWork(
            limM: 50_000, limT: 50_000, cntM: 10_000, cntT: 10_000,
            doneM: false, doneT: false, onlineM: false, onlineT: false, rowsThisRun: 100))
    }

    /// jdb 未 done（不限额）且 sht done → true（一源完成不妨碍另一源）
    func test_unlimitedJdbStillWorksWhileShtDone() {
        XCTAssertTrue(TargetPlanPolicy.moreWork(
            limM: 0, limT: 50_000, cntM: 10_000, cntT: 10_000,
            doneM: false, doneT: true, onlineM: true, onlineT: true, rowsThisRun: 100))
    }

    /// sht target=0（不限）→ true（jdb 已 done 不影响）
    func test_unlimitedShtStillWorks() {
        XCTAssertTrue(TargetPlanPolicy.moreWork(
            limM: 50_000, limT: 0, cntM: 10_000, cntT: 10_000,
            doneM: true, doneT: false, onlineM: true, onlineT: true, rowsThisRun: 100))
    }

    /// 49_000 < 50_000 → true（未达上限继续拉）
    func test_cappedBelowLimitWorks() {
        XCTAssertTrue(TargetPlanPolicy.moreWork(
            limM: 50_000, limT: 50_000, cntM: 49_000, cntT: 49_000,
            doneM: false, doneT: true, onlineM: true, onlineT: true, rowsThisRun: 100))
    }

    /// 60_000 >= 50_000 → false（已达上限停止）
    func test_cappedAtLimitStops() {
        XCTAssertFalse(TargetPlanPolicy.moreWork(
            limM: 50_000, limT: 50_000, cntM: 60_000, cntT: 60_000,
            doneM: false, doneT: true, onlineM: true, onlineT: true, rowsThisRun: 100))
    }

    /// 一源离线、另一源有行可拉 → true（按源独立判定）
    func test_oneSourceOfflineOtherHasRows() {
        XCTAssertTrue(TargetPlanPolicy.moreWork(
            limM: 50_000, limT: 50_000, cntM: 10_000, cntT: 10_000,
            doneM: false, doneT: false, onlineM: false, onlineT: true, rowsThisRun: 100))
    }

    /// rows=-5 → false（负数防御；即使双源在线、不限额、均未 done）
    func test_negativeRowsMeansNoWork() {
        XCTAssertFalse(TargetPlanPolicy.moreWork(
            limM: 0, limT: 0, cntM: 0, cntT: 0,
            doneM: false, doneT: false, onlineM: true, onlineT: true, rowsThisRun: -5))
    }
}
