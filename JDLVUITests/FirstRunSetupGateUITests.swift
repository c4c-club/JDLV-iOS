import XCTest

// R6 SEG-01：首启门禁回归 —— 800ms 防抖 autoSave 不得驱动门禁换页；
// 仅「完成配置并进入」（first_run_done）经 flush+校验后进首页（tab_search 出现）。
final class FirstRunSetupGateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 空配置启动（无 -JDLV_DEMO）→ 应停在首启门禁页
    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        // A9/R8：独立 defaults suite + 独立 Keychain service（防跨用例持久污染）
        app.launchArguments = ["-JDLV_DEFAULTS_SUITE", "firstrun_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    private let settle: TimeInterval = 2.5   // > 800ms 防抖窗口；旧实现此间隙内即被换页

    func testTypingPauseDoesNotExitGate() throws {
        let app = launchFresh()
        let goSettings = app.buttons["first_run_go_settings"]
        XCTAssertTrue(goSettings.waitForExistence(timeout: 15), "首启说明卡未出现")
        goSettings.tap()

        let page = app.descendants(matching: .any)["settings_page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "设置页未出现")

        let host = app.textFields["dsfield_remote_host"]
        let port = app.textFields["dsfield_remote_port"]
        let user = app.textFields["dsfield_remote_user"]
        let pass = app.secureTextFields["dsfield_remote_pass"]
        let jdb = app.textFields["dsfield_remote_jdb"]
        let sht = app.textFields["dsfield_remote_sht"]
        for f in [host, port, user, jdb, sht] {
            XCTAssertTrue(f.waitForExistence(timeout: 8), "连接字段缺失: \(f.identifier)")
        }
        XCTAssertTrue(pass.waitForExistence(timeout: 8), "连接字段缺失: dsfield_remote_pass")

        fill(app, host, "10.0.0.2")
        fill(app, port, "3306")
        fill(app, user, "uit")
        fill(app, jdb, "jdb")
        fill(app, sht, "sht")
        fill(app, pass, "p")   // 密码只输一半

        // 停顿 > 800ms 防抖窗口，再点其他字段制造键盘切换
        Thread.sleep(forTimeInterval: settle)
        host.tap()
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(page.exists, "停顿/切键盘后门禁页被换页（SEG-01 回归）")
        XCTAssertFalse(app.buttons["tab_search"].exists, "不应自动进入首页 Tab")

        // 补全密码 → 仍应停留在首启页（防抖落盘不换页）
        pass.tap()
        pass.typeText("2")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(page.exists, "补全密码后仍应停留在首启页")

        // 显式完成：flush + 校验 → 进首页
        let done = app.buttons["first_run_done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "完成按钮不存在")
        done.tap()

        let tabBar = app.buttons["tab_search"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "完成配置后未进入首页")
    }

    func testIncompleteDoneStaysInGate() throws {
        let app = launchFresh()
        let goSettings = app.buttons["first_run_go_settings"]
        XCTAssertTrue(goSettings.waitForExistence(timeout: 15), "首启说明卡未出现")
        goSettings.tap()

        let page = app.descendants(matching: .any)["settings_page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "设置页未出现")

        let host = app.textFields["dsfield_remote_host"]
        XCTAssertTrue(host.waitForExistence(timeout: 8), "连接字段缺失")
        fill(app, host, "10.0.0.3")

        let done = app.buttons["first_run_done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "完成按钮不存在")
        done.tap()

        let err = app.descendants(matching: .any)["first_run_done_error"]
        XCTAssertTrue(err.waitForExistence(timeout: 8), "未出现行内错误提示")
        XCTAssertTrue(page.exists, "配置不完整点完成不应退出首启页")
        XCTAssertFalse(app.buttons["tab_search"].exists, "配置不完整不应进入首页")
    }

    /// 滚动到可点（jdb/sht 字段在首启卡下部，小屏可能折叠线以下）
    private func fill(_ app: XCUIApplication, _ field: XCUIElement, _ text: String) {
        for _ in 0..<6 where !field.isHittable {
            app.swipeUp()
        }
        field.tap()
        // B2：CI 模拟器 typeText 偶发丢字符 —— 失败重试一次
        do { try field.typeText(text) }
        catch {
            field.tap()
            try? field.typeText(text)
        }
    }
}
