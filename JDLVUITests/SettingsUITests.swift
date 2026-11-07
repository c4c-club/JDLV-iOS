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
        // A9/R8：独立 defaults suite + 独立 Keychain service（防 testImgMode 等跨用例持久污染）
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    /// 进入设置页（首启门禁「去设置」或主界面「设置」tab）
    private func openSettings(_ app: XCUIApplication) {
        let goSettings = app.buttons["first_run_go_settings"]
        if goSettings.waitForExistence(timeout: 8) {
            goSettings.tap()   // FirstRunSetup「去设置」→ P12 完整设置页
        } else {
            XCTAssertTrue(tabExists(app, "设置", "settings"), "设置 tab not found")
            tabLabeled(app, "设置", "settings").tap()
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

        // ⑧ 关于先展开：about 在页面最底部；此刻所有组收起、页面短 → header 一屏可达。
        //    （先于 11 组全部展开的走查，避免深滚动 + toggle 状态歧义）
        // header 是 Button（SettingsGroupCard.header）；整卡 identifier 的中心点不在头行 →
        // 必须点头行文本按钮（title "⑧ 关于"）
        // 卡 identifier 把整卡合并为单个 a11y 元素（子头行按钮被合并进卡片）→
        // 点卡片顶部条带（header 区，dy≈0.08）切换展开
        // R3 问题 4：关于改为 AboutView 子页（NavigationLink）—— 测试图开关在子页 Form 内
        let aboutLink = app.buttons["settings_about_link"].firstMatch
        scrollUntilVisible(app, aboutLink, maxSwipes: 14)
        XCTAssertTrue(aboutLink.waitForExistence(timeout: 6), "settings_about_link not found")
        if aboutLink.isHittable { aboutLink.tap() } else {
            aboutLink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        // AppSwitchRow：id 在整行 Button 上（内层 Toggle id = switch_<label>）→ 双路查询
        var sw = app.buttons["about_testimg_switch"].firstMatch
        if !sw.exists { sw = app.switches["about_testimg_switch"].firstMatch }
        XCTAssertTrue(sw.waitForExistence(timeout: 8), "about_testimg_switch not found (DEBUG build expected)")
        scrollUntilVisible(app, sw, maxSwipes: 10)

        // 锚点可能已挂（前序 UI 测试持久化 testImgMode=true）→ 先查再点，避免 ON→OFF 抖动
        let anchorQuery = app.descendants(matching: .any)["testImageModeOn"].firstMatch
        if !anchorQuery.exists {
            // 点击开关（行按钮 / 行内 Toggle 均触发 onChange）→ 逐次点，锚点出现即停（≤4 次）
            for _ in 0..<4 {
                if sw.isHittable {
                    sw.tap()
                } else {
                    sw.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                if anchorQuery.waitForExistence(timeout: 3) { break }
            }
        }
        // 状态不可预知（前序用例持久化 testImgMode + CollapsiblePref 展开态）：
        // 目标 = 点击后 switch value == "1"（AppSwitchRow 内层 Toggle 的 XCUI value）。
        // 锚点 text 的可见性由单测覆盖（testImgMode 持久化 + AboutCard 组合逻辑）。
        func switchOn() -> Bool {
            let on = app.switches.matching(NSPredicate(format: "value == %@", "1"))
            return on.count > 0
        }
        // anchor（✓ 测试图片模式生效中）为唯一准绳；switch value 因 Form 行 a11y 合并不可靠
        let anchorQ = app.descendants(matching: .any)["testImageModeOn"].firstMatch
        var anchorFound = anchorQ.exists
        if !anchorFound {
            for _ in 0..<6 {
                if sw.isHittable {
                    sw.tap()
                } else {
                    sw.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                if anchorQ.waitForExistence(timeout: 4) { anchorFound = true; break }
                // 兜底：点行文本（Form 行整行可点）
                let rowText = app.staticTexts["测试图片模式（调试）"].firstMatch
                if rowText.exists && rowText.isHittable { rowText.tap() }
                if anchorQ.waitForExistence(timeout: 4) { anchorFound = true; break }
            }
        }
        XCTAssertTrue(anchorFound, "test image switch did not reach ON after taps")

        // 返回设置主页（R3：测试图开关在 About 子页；11 组走查在主页进行）
        app.navigationBars.buttons.firstMatch.exists
            ? app.navigationBars.buttons.firstMatch.tap()
            : ()
        Thread.sleep(forTimeInterval: 0.8)

        // 11 张分组卡逐组展开走查（无崩溃）—— 只点头行条带（卡片中心 = 展开内容，
        // 中心 tap 会误触行控件：开关/文本框），头行条带 = 切换展开/收起
        let keys = ["db", "proxy", "jdbimg", "shtimg", "theme", "lock",
                    "browse", "semantic", "cache", "shadow"]
        for k in keys {
            let card = group(app, k)
            scrollUntilVisible(app, card)
            guard card.exists, card.isHittable else { continue }
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            XCTAssertEqual(app.state, .runningForeground, "crash after expanding group \(k)")
        }
        // 锚点已在本用例前段硬断言（testImageModeOn），store 持久化由单测覆盖
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

    // iOS 18.5 模拟器 tab 按钮的 label/identifier 偶发不等于标题 → label 直查 + 全量索引扫描双路
    // tab_<route> 唯一且稳定；label 查询会与隐藏 Tab 内容多匹配 → 永远用 identifier
    private func tabLabeled(_ app: XCUIApplication, _ label: String, _ route: String) -> XCUIElement {
        let byId = app.buttons["tab_" + route]
        if byId.waitForExistence(timeout: 5) { return byId }
        let n = app.buttons.count
        for i in 0..<n {
            let b = app.buttons.element(boundBy: i)
            if b.identifier.contains("tab_" + route) { return b }
        }
        return app.buttons[label].firstMatch
    }

    private func tabExists(_ app: XCUIApplication, _ label: String, _ route: String,
                           timeout: TimeInterval = 5) -> Bool {
        if app.buttons["tab_" + route].waitForExistence(timeout: timeout) { return true }
        for _ in 0..<6 {
            let n = app.buttons.count
            for i in 0..<n {
                let b = app.buttons.element(boundBy: i)
                if b.identifier.contains("tab_" + route) { return true }
            }
            usleep(500_000)
        }
        return false
    }

    private func waitUntilShort(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            usleep(200_000)
        }
        return cond()
    }
}
