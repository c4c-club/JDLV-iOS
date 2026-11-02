//
//  WarmGateTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/WarmGateTest.kt（规格文档 B17）
//  用例数: 16（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.WarmGate.shouldStart(WarmGateInput)/reason（预热巡检门禁，短路序）
//        background → not-idle(≤3000ms) → disabled → running → not-wifi
//        → source-pending → due → backoff；自动起跑仅当 reason ∈ {source-pending, due}
//
//  默认输入（规格首行）：前台 + 空闲 4s + 开关开 + 未在跑 + wifi + 双源在线
//  + jdb/sht 未 done + 演员 done + 演员启用 + now(10_000) < nextRunAt(20_000)
//  → reason=="source-pending"、shouldStart==true
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class WarmGateTests: XCTestCase {

    // MARK: - 默认输入（规格文档 B17 首行）

    private func defaultInput() -> WarmGateInput {
        WarmGateInput(
            foreground: true, idleMs: 4_000, enabled: true, running: false, wifi: true,
            onlineM: true, onlineT: true, doneM: false, doneT: false, doneA: true,
            actorsEnabled: true, now: 10_000, nextRunAt: 20_000
        )
    }

    // MARK: - B17. WarmGateTest（16 用例）

    /// 默认输入 → shouldStart=true
    func test_startsWhenSourcePending() {
        let i = defaultInput()
        XCTAssertTrue(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "source-pending")
    }

    /// foreground=false → false；reason=="background"
    func test_backgroundNeverStarts() {
        var i = defaultInput()
        i.foreground = false
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "background")
    }

    /// idleMs=3000 → false（3s 边界不算空闲）；reason=="not-idle"
    func test_notIdleAtThreeSecondsBoundary() {
        var i = defaultInput()
        i.idleMs = 3_000
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "not-idle")
    }

    /// idleMs=3001 → true
    func test_startsJustAfterThreeSeconds() {
        var i = defaultInput()
        i.idleMs = 3_001
        XCTAssertTrue(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "source-pending")
    }

    /// enabled=false → false；reason=="disabled"
    func test_disabledNeverStarts() {
        var i = defaultInput()
        i.enabled = false
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "disabled")
    }

    /// running=true → false（单飞）；reason=="running"
    func test_runningNeverStarts() {
        var i = defaultInput()
        i.running = true
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "running")
    }

    /// wifi=false → false（仅 WiFi 预热）；reason=="not-wifi"
    func test_mobileNetworkNeverStarts() {
        var i = defaultInput()
        i.wifi = false
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "not-wifi")
    }

    /// jdb 离线 + sht done + 演员 done → false；reason=="backoff"
    /// （全部 pending 工作不可达：onlineM=false 掐掉 pendingM/pendingA，doneT=true 掐掉 pendingT；且未到期）
    func test_jdbOfflineShtOnlineAndDoneDoesNotStart() {
        var i = defaultInput()
        i.onlineM = false   // jdb 离线
        i.doneT = true      // sht 已完成
        i.doneA = true      // 演员已完成（默认即 true，显式写出对应规格）
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "backoff")
    }

    /// jdb 离线 + sht pending → true（按源独立，sht 可继续）
    func test_jdbOfflineShtOnlinePendingStarts() {
        var i = defaultInput()
        i.onlineM = false   // jdb 离线；sht 在线且未 done → pendingT
        XCTAssertTrue(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "source-pending")
    }

    /// doneM/T=true、doneA=false、actorsEnabled=false → false
    /// （演员禁用时其未完成不构成待办）；reason=="backoff"
    func test_actorsDisabledIgnoresActorDone() {
        var i = defaultInput()
        i.doneM = true
        i.doneT = true
        i.doneA = false
        i.actorsEnabled = false
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "backoff")
    }

    /// doneM/T=true、doneA=false、actorsEnabled=true → true（演员待办触发）
    func test_actorsEnabledAndPendingStarts() {
        var i = defaultInput()
        i.doneM = true
        i.doneT = true
        i.doneA = false
        i.actorsEnabled = true
        XCTAssertTrue(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "source-pending")
    }

    /// 全部 done 后 now(10_000)<nextRunAt(20_000) → false；reason=="backoff"
    func test_nextRunNotReachedDoesNotStart() {
        var i = defaultInput()
        i.doneM = true
        i.doneT = true
        // doneA 默认 true → 无 pending，且未到期
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "backoff")
    }

    /// 全部 done 后 now==next(20_000) → true（到期即启动）；reason=="due"
    func test_nextRunReachedStarts() {
        var i = defaultInput()
        i.doneM = true
        i.doneT = true
        i.now = 20_000      // == nextRunAt（边界含等号）
        XCTAssertTrue(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "due")
    }

    /// 双源离线 + 未 done + now(30_000)>next(20_000) → true（到期巡检允许离线尝试）；reason=="due"
    func test_bothOfflineButDueStarts() {
        var i = defaultInput()
        i.onlineM = false
        i.onlineT = false
        i.now = 30_000
        XCTAssertTrue(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "due")
    }

    /// 双源离线 + 未到期 → false；reason=="backoff"
    func test_bothOfflineNotDueDoesNotStart() {
        var i = defaultInput()
        i.onlineM = false
        i.onlineT = false
        XCTAssertFalse(WarmGate.shouldStart(i))
        XCTAssertEqual(WarmGate.reason(i), "backoff")
    }

    /// 默认输入 reason=="source-pending"（文案稳定锁定）
    func test_reasonSourcePendingIsStable() {
        XCTAssertEqual(WarmGate.reason(defaultInput()), "source-pending")
    }
}
