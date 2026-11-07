import XCTest
@testable import JDLV

// R3 问题 4：全局保存状态单测（13 §6.1 SaveStateTests）。
// 六条写通道最终态不得停在 .saving；5s watchdog 超时路径用短间隔模拟（noteSaving 手动触发）。
@MainActor
final class SaveStateTests: XCTestCase {

    private var wiped: Set<String> = []

    private func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "test_savestate_\(tag)"
        if !wiped.contains(tag) {
            UserDefaults().removePersistentDomain(forName: name)
            wiped.insert(tag)
        }
        return UserDefaults(suiteName: name)!
    }

    private func makeStore(_ tag: String) -> SettingsStore {
        SettingsStore(defaults: freshDefaults(tag))
    }

    func testUpdateSettingsSavesAndReports() {
        let store = makeStore("update")
        store.noteSaving()
        store.updateSettings { $0.viewMode = 1 }
        if case .saved = store.saveState {} else {
            XCTFail("updateSettings 值变 → .saved，实际 \(store.saveState)")
        }
    }

    func testUpdateSettingsNoChange() {
        let store = makeStore("nochange")
        let before = store.settings.viewMode
        store.updateSettings { $0.viewMode = before }
        if case .noChange = store.saveState {} else {
            XCTFail("值未变 → .noChange，实际 \(store.saveState)")
        }
    }

    func testUpdateSettingsNowAndAutoSaveExitSaving() async {
        let store = makeStore("now")
        let r1 = await store.updateSettingsNow { $0.perPage = 30 }
        XCTAssertNotEqual(SaveResult.saving, r1, "updateSettingsNow 必须返回终态")
        if case .saving = store.saveState { XCTFail("updateSettingsNow 后不得停留 .saving") }

        let r2 = await store.autoSave { $0.perPage = 40 }
        XCTAssertNotEqual(SaveResult.saving, r2, "autoSave 必须返回终态")
        if case .saving = store.saveState { XCTFail("autoSave 后不得停留 .saving") }
    }

    func testEditNowAndFlushExitSaving() async {
        let store = makeStore("edit")
        store.edit { $0.perPage = 60 }
        _ = await store.editNow { $0.perPage = 70 }
        if case .saving = store.saveState { XCTFail("editNow 后不得停留 .saving") }

        store.edit { $0.perPage = 80 }
        await store.flushPendingEdits()
        if case .saving = store.saveState { XCTFail("flushPendingEdits 后不得停留 .saving") }
        XCTAssertEqual(store.settings.perPage, 80, "flush 后全链编辑已落盘")
    }

    func testApplyLockChangeExitsSaving() async {
        let store = makeStore("lock")
        let r = await store.applyLockChange(enabled: false, type: "none", secretHash: "")
        XCTAssertNotEqual(SaveResult.saving, r, "applyLockChange 必须返回终态")
        if case .saving = store.saveState { XCTFail("applyLockChange 后不得停留 .saving") }
    }

    func testWatchdogTimeoutMarksFailed() async {
        let store = makeStore("watchdog")
        store.noteSaving()
        if case .saving = store.saveState {} else {
            XCTFail("noteSaving → .saving")
        }
        // 等待 watchdog（5s + 余量）
        try? await Task.sleep(nanoseconds: 5_600_000_000)
        guard case .failed(let msg, _) = store.saveState else {
            XCTFail("5s 未完成 → watchdog 应置 .failed，实际 \(store.saveState)")
            return
        }
        XCTAssertEqual(msg, "保存超时")
    }
}
