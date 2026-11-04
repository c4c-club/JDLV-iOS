import XCTest

//
//  SettingsUITests.swift —— P12 设置页走查（UI）。
//
//  - launch -JDLV_DEMO 1 → 进设置（首启门禁走「去设置」→ 完整设置页；已配置走「设置」tab）；
//  - 11 张分组卡逐组展开走查（无崩溃）；
//  - ⑧ 关于 → 开启「测试图片模式（调试）」开关 → 断言 accessibilityIdentifier
//    "testImageModeOn" 出现（★ P13 截图前置锚点）；
//  - 主题 chip 点击 → 保存三态行（无变化）出现。
//
final class SettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1"]
        app.launch()
        return app
    }

    /// 进入设置页（首启门禁「去设置」或主界面「设置」tab）
    private func openSettings(_ app: XCUIApplication) {
        let goSettings = app.buttons["first_run_go_settings"]
        if goSettings.waitForExistence(timeout: 8) {
            goSettings.tap()   // FirstRunSetup「去设置」→ P12 完整设置页
        } else {
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "tab bar not found")
            let btn = tabBar.buttons["设置"]
            XCTAssertTrue(btn.waitForExistence(timeout: 5), "设置 tab not found")
            btn.tap()
        }
        let page = app.descendants(matching: .any)["settings_page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "settings page not found")
    }

    private func scrollUntilVisible(_ app: XCUIApplication, _ el: XCUIElement, maxSwipes: Int = 14) {
        var i = 0
        while !(el.exists && el.isHittable) && i < maxSwipes {
            app.swipeUp()
            i += 1
        }
    }

    private func group(_ app: XCUIApplication, _ key: String) -> XCUIElement {
        app.descendants(matching: .any)["settings_group_\(key)"].firstMatch
    }

    // MARK: 主走查：逐组展开 → ⑧关于 → 测试图片模式锚点

    func testSettingsWalkthroughAndTestImageModeAnchor() throws {
        let app = launchDemo()
        openSettings(app)

        // 11 张分组卡逐组展开走查（无崩溃）
        let keys = ["db", "proxy", "jdbimg", "shtimg", "theme", "lock",
                    "browse", "semantic", "cache", "shadow", "about"]
        for k in keys {
            let header = group(app, k)
            scrollUntilVisible(app, header)
            guard header.exists else { continue }
            header.tap()
            XCTAssertEqual(app.state, .runningForeground, "crash after expanding group \(k)")
        }

        // ⑧ 关于 → 开启「测试图片模式（调试）」（仅 DEBUG 构建显示）
        let aboutGroup = group(app, "about")
        scrollUntilVisible(app, aboutGroup)
        if !aboutGroup.isHittable { app.swipeUp() }

        let sw = app.descendants(matching: .any)["about_testimg_switch"].firstMatch
        scrollUntilVisible(app, sw)
        XCTAssertTrue(sw.exists, "about_testimg_switch not found (DEBUG build expected)")
        sw.tap()

        // ★ P13 截图前置锚点：测试图片模式开启即出现
        let anchor = app.descendants(matching: .any)["testImageModeOn"].firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 5), "testImageModeOn anchor not found")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: 主题 chip 点击 → 保存三态行出现（无变化/已保存 均可）

    func testThemeChipTriggersSaveStateLine() throws {
        let app = launchDemo()
        openSettings(app)

        let themeGroup = group(app, "theme")
        scrollUntilVisible(app, themeGroup)
        XCTAssertTrue(themeGroup.waitForExistence(timeout: 5), "theme group not found")
        themeGroup.tap()   // 展开

        // 点「跟随系统」chip（深色为默认 → 预期「无变化」；文案二态均可接受）
        let chip = app.buttons["跟随系统"].firstMatch
        scrollUntilVisible(app, chip)
        if chip.exists {
            chip.tap()
            let state = app.descendants(matching: .any)["settings_save_state"].firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 5), "save state line not shown")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: 折叠记忆：展开后收起（二次点击），无崩溃

    func testGroupExpandCollapseNoCrash() throws {
        let app = launchDemo()
        openSettings(app)

        let dbGroup = group(app, "db")
        // ① 数据源在首启门禁路径下默认展开；二次点击收起再展开
        XCTAssertTrue(dbGroup.waitForExistence(timeout: 5), "db group not found")
        dbGroup.tap()
        XCTAssertEqual(app.state, .runningForeground, "crash after collapsing db group")
        dbGroup.tap()
        XCTAssertEqual(app.state, .runningForeground, "crash after re-expanding db group")
    }
}
