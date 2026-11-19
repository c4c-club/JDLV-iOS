import XCTest

//
//  ShtFilterMemoryUITests.swift —— R7-P6（任务 07 步骤 5）98t 筛选记忆跨进程验证。
//
//  固定 DEFAULTS_SUITE：同一 suite 内 terminate → launch 共享 UserDefaults，
//  验证筛选落盘与冷启动恢复（AppSettings sht_main/sht_cat/sht_type）。
//  副版/分类三键的落盘/恢复/级联校验在 ShtVMTests + SettingsTests 覆盖;
//  本用例走 UI 主版记忆 + 重置闭环（demo 数据源计数随 demo 种子走, 断言用 CONTAINS）。
//
final class ShtFilterMemoryUITests: XCTestCase {

    /// 固定 suite：跨 terminate/launch 保持（不用 UUID —— 记忆测试需要持久化语义）
    private let suite = "uitest_shtmem_fixed"

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", suite,
                               "-JDLV_KEYCHAIN_SERVICE", "ks_shtmem_fixed"]
        app.launch()
        return app
    }

    @MainActor
    private func gotoSht(_ app: XCUIApplication) {
        let shtTab = app.buttons["tab_sht"].firstMatch
        XCTAssertTrue(shtTab.waitForExistence(timeout: 20), "tab bar not found")
        if shtTab.isHittable {
            shtTab.tap()
        } else {
            shtTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["sht_grid"].firstMatch
            .waitForExistence(timeout: 60), "98t grid not rendered")
    }

    @MainActor
    private func openFilterSheet(_ app: XCUIApplication) {
        app.buttons["sht_filter_button"].firstMatch.tap()
        let mainPicker = app.descendants(matching: .any)["sht_main_picker"].firstMatch
        XCTAssertTrue(mainPicker.waitForExistence(timeout: 15), "筛选 sheet 未渲染主版 Picker")
    }

    @MainActor
    private func closeFilterSheet(_ app: XCUIApplication) {
        let done = app.buttons["sht_filter_done"].firstMatch
        if done.waitForExistence(timeout: 6) {
            done.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(app.descendants(matching: .any)["sht_grid"].firstMatch
            .waitForExistence(timeout: 10), "关闭 sheet 后列表未恢复")
    }

    @MainActor
    private func pickMain(_ app: XCUIApplication, label: String) {
        let mainPicker = app.descendants(matching: .any)["sht_main_picker"].firstMatch
        mainPicker.tap()
        let opt = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        if opt.waitForExistence(timeout: 8) {
            opt.tap()
        } else {
            let alt = app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            XCTAssertTrue(alt.waitForExistence(timeout: 8), "主版选项 \(label) 未出现")
            alt.tap()
        }
    }

    @MainActor
    func testFilterMemoryAcrossRelaunchAndReset() throws {
        let app = launchApp()
        gotoSht(app)

        // ① 清残留（固定 suite 可能有上轮 CI 的记忆）：打开筛选 → 重置 → 落盘清空
        openFilterSheet(app)
        let resetBtn = app.buttons["sht_filter_reset"].firstMatch
        // Form 是懒加载 List：重置 Section 屏外时不在 AX 树，需滚到底
        if !resetBtn.waitForExistence(timeout: 4) {
            app.swipeUp()
            if !resetBtn.waitForExistence(timeout: 4) { app.swipeUp() }
        }
        XCTAssertTrue(resetBtn.waitForExistence(timeout: 6), "sheet 内无重置按钮")
        resetBtn.tap()
        closeFilterSheet(app)

        // ② 设主版记忆 → terminate
        openFilterSheet(app)
        pickMain(app, label: "有码中文字幕")
        closeFilterSheet(app)
        app.terminate()

        // ③ 冷启动 → 记忆恢复：主版 Picker 值 = 所选版区，首卡按记忆筛选渲染
        let app2 = launchApp()
        gotoSht(app2)
        openFilterSheet(app2)
        let mp = app2.descendants(matching: .any)["sht_main_picker"].firstMatch
        let v = (mp.value as? String) ?? ""
        XCTAssertTrue(v.contains("有码中文字幕"),
                      "重启后主版 Picker 未恢复记忆值, 实际: \(v)")
        closeFilterSheet(app2)
        XCTAssertTrue(app2.descendants(matching: .any)["shtcard_0"].firstMatch
            .waitForExistence(timeout: 30), "按记忆筛选后首卡未渲染")
        XCTAssertTrue(app2.descendants(matching: .any)["sht_filter_badge"].firstMatch
            .exists, "筛选 badge 未随记忆恢复显示")
        app2.terminate()

        // ④ 重置 → 重启 → 回到全部（badge 消失）
        let app3 = launchApp()
        gotoSht(app3)
        openFilterSheet(app3)
        let reset3 = app3.buttons["sht_filter_reset"].firstMatch
        if !reset3.waitForExistence(timeout: 4) {
            app3.swipeUp()
            if !reset3.waitForExistence(timeout: 4) { app3.swipeUp() }
        }
        XCTAssertTrue(reset3.waitForExistence(timeout: 6), "sheet 内无重置按钮(第二次)")
        reset3.tap()
        closeFilterSheet(app3)
        app3.terminate()

        let app4 = launchApp()
        gotoSht(app4)
        openFilterSheet(app4)
        let mp4 = app4.descendants(matching: .any)["sht_main_picker"].firstMatch
        let v4 = (mp4.value as? String) ?? ""
        XCTAssertTrue(v4.contains("全部"), "重置重启后主版应回到全部, 实际: \(v4)")
        XCTAssertFalse(app4.descendants(matching: .any)["sht_filter_badge"].firstMatch
            .exists, "重置后筛选 badge 应消失")
        closeFilterSheet(app4)
    }
}
