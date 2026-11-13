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

    /// 进入设置页（首启门禁「去设置」或主界面「设置」tab）。
    /// 返回【打开耗时】—— 从点击入口元素到 settings_page 出现（launch/门禁等待不计入，
    /// R5 P3：CI 上 "Setting up automation session" 曾占用 78s，计入会假阴超预算）。
    @discardableResult
    private func openSettings(_ app: XCUIApplication) -> TimeInterval {
        let goSettings = app.buttons["first_run_go_settings"]
        if goSettings.waitForExistence(timeout: 8) {
            let openStart = Date()
            goSettings.tap()   // FirstRunSetup「去设置」→ P12 完整设置页
            // 首帧/构建落定（繁忙主线程上 AX 快照易超时：run 43338529818 walk :86）
            Thread.sleep(forTimeInterval: 1.0)
            assertSettingsPage(app)
            return Date().timeIntervalSince(openStart)
        } else {
            XCTAssertTrue(tabExists(app, "设置", "settings"), "设置 tab not found")
            let openStart = Date()
            tabLabeled(app, "设置", "settings").tap()
            Thread.sleep(forTimeInterval: 1.0)
            assertSettingsPage(app)
            return Date().timeIntervalSince(openStart)
        }
    }

    /// settings_page 断言（identifier 在 ScrollView 上 → 类型化查询优先，全树兜底）
    private func assertSettingsPage(_ app: XCUIApplication) {
        let typed = app.scrollViews["settings_page"].firstMatch
        if typed.waitForExistence(timeout: 10) { return }
        let any = app.descendants(matching: .any)["settings_page"].firstMatch
        XCTAssertTrue(any.waitForExistence(timeout: 10), "settings page not found")
    }

    /// R5 P3：失败时附截图 + AX 树 dump（可复核，不盲猜）
    private func failWithDump(_ app: XCUIApplication, _ reason: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "diag-target-miss"
        shot.lifetime = .keepAlways
        add(shot)
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = "diag-tree-dump"
        dump.lifetime = .keepAlways
        add(dump)
        XCTFail(reason, file: file, line: line)
    }

    /// R5 P3：确定性滚动定位（替换旧 while !(exists && isHittable) —— 每次循环对全 app
    /// 重新求 AX 快照是 "Timed out while evaluating UI query" 的根因）。
    /// 1) waitForExistence(5)；2) 有限次 swipeUp（默认 ≤12，每次 0.2s），每步只查
    ///    exists + frame∩window（帧数据，不做 hittable 快照）；3) 找不到 → XCTFail+dump。
    @discardableResult
    private func scrollToElement(_ app: XCUIApplication, _ el: XCUIElement,
                                 maxSwipes: Int = 12,
                                 file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if !el.exists && !el.waitForExistence(timeout: 5) {
            // LazyVStack 未布局时元素不在树里 → 边滚边查
            for _ in 0..<maxSwipes {
                app.swipeUp()
                usleep(200_000)
                if el.exists { break }
            }
        }
        guard el.exists else {
            failWithDump(app, "\(el) not found after \(maxSwipes) swipes", file: file, line: line)
            return false
        }
        // R5 P3：按元素在视口上方/下方决定滑动方向（走查从页底回顶部找 db 卡需向上回滚）
        for _ in 0..<maxSwipes {
            let f = el.frame
            if f.intersects(app.frame) { return true }
            if f.maxY < 0 { app.swipeDown() } else { app.swipeUp() }
            usleep(200_000)
        }
        // R5 P3 稳定确认：滚动惯性未停时 frame 会迁移 → tap 报 not-hittable
        // （run 43338529818 证据：ds_test_button 在视口内 tap 仍失败）。300ms 后仍在视口才通过。
        usleep(300_000)
        if el.exists && el.frame.intersects(app.frame) { return true }
        for _ in 0..<3 {
            let f = el.frame
            if f.intersects(app.frame) { return true }
            if f.maxY < 0 { app.swipeDown() } else { app.swipeUp() }
            usleep(400_000)
        }
        guard el.frame.intersects(app.frame) else {
            failWithDump(app, "\(el) found but outside window after \(maxSwipes) swipes",
                         file: file, line: line)
            return false
        }
        return true
    }

    private func group(_ app: XCUIApplication, _ key: String) -> XCUIElement {
        app.descendants(matching: .any)["settings_group_\(key)"].firstMatch
    }

    // MARK: 主走查：逐组展开 → ⑧关于 → 测试图片模式锚点

    func testSettingsWalkthroughAndTestImageModeAnchor() throws {
        let app = launchDemo()
        // R5 P3 预算测量：设置页打开耗时（点击入口 → settings_page 出现；
        // launch/门禁等待不计入 —— run 43331622094 证据：automation session 卡 78s
        // 计入后 13.34s 假阴超预算）
        let openSeconds = openSettings(app)
        XCTAssertTrue(openSeconds <= 6.0,
                      "设置页打开 \(String(format: "%.2f", openSeconds))s 超预算（5s + 20% 容差）")
        recordMeasured("settings_open_seconds", openSeconds)

        // ⑧ 关于先展开：about 在页面最底部；此刻所有组收起、页面短 → header 一屏可达。
        //    （先于 11 组全部展开的走查，避免深滚动 + toggle 状态歧义）
        // R3 问题 4：关于改为 AboutView 子页（NavigationLink）—— 测试图开关在子页 Form 内
        // R5 P3 预算测量：滚到底耗时（settings_group 卡全部收起态滚到 about 链接）
        let scrollStart = Date()
        let aboutLink = app.buttons["settings_about_link"].firstMatch
        XCTAssertTrue(scrollToElement(app, aboutLink, maxSwipes: 12),
                      "settings_about_link 定位失败")
        let scrollSeconds = Date().timeIntervalSince(scrollStart)
        XCTAssertTrue(scrollSeconds <= 18.0,
                      "滚到底 \(String(format: "%.2f", scrollSeconds))s 超预算（15s + 20% 容差）")
        recordMeasured("settings_scroll_bottom_seconds", scrollSeconds)

        // identifier 在头行按钮上（settings_about_link）→ 精确 tap，不再坐标兜底
        aboutLink.tap()
        // AppSwitchRow：id 在整行 Button 上（内层 Toggle id = switch_<label>）→ 双路查询
        var sw = app.buttons["about_testimg_switch"].firstMatch
        if !sw.exists { sw = app.switches["about_testimg_switch"].firstMatch }
        XCTAssertTrue(sw.waitForExistence(timeout: 8), "about_testimg_switch not found (DEBUG build expected)")
        XCTAssertTrue(scrollToElement(app, sw, maxSwipes: 10), "about_testimg_scroll fail")

        // 锚点可能已挂（前序 UI 测试持久化 testImgMode=true）→ 先查再点，避免 ON→OFF 抖动
        let anchorQuery = app.descendants(matching: .any)["testImageModeOn"].firstMatch
        if !anchorQuery.exists {
            // 点击开关（行按钮 / 行内 Toggle 均触发 onChange）→ 逐次点，锚点出现即停（≤4 次）
            for _ in 0..<4 {
                scrollToElement(app, sw, maxSwipes: 4)
                sw.tap()
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
                scrollToElement(app, sw, maxSwipes: 4)
                sw.tap()
                if anchorQ.waitForExistence(timeout: 4) { anchorFound = true; break }
                // 兜底：点行文本（Form 行整行可点）
                let rowText = app.staticTexts["测试图片模式（调试）"].firstMatch
                if rowText.exists && rowText.frame.intersects(app.frame) { rowText.tap() }
                if anchorQ.waitForExistence(timeout: 4) { anchorFound = true; break }
            }
        }
        XCTAssertTrue(anchorFound, "test image switch did not reach ON after taps")

        // 返回设置主页（R3：测试图开关在 About 子页；11 组走查在主页进行）
        app.navigationBars.buttons.firstMatch.exists
            ? app.navigationBars.buttons.firstMatch.tap()
            : ()
        Thread.sleep(forTimeInterval: 0.8)

        // 11 张分组卡逐组展开走查（无崩溃）—— settings_group_<key> identifier 就在头行
        // 按钮上（SettingsGroupCard.header）→ 精确 tap 头行切换展开，无坐标兜底
        let keys = ["db", "proxy", "jdbimg", "shtimg", "theme", "lock",
                    "browse", "semantic", "cache", "shadow"]
        for k in keys {
            let card = group(app, k)
            guard scrollToElement(app, card) else { continue }   // 失败已附 dump
            card.tap()
            XCTAssertEqual(app.state, .runningForeground, "crash after expanding group \(k)")
        }
        // 锚点已在本用例前段硬断言（testImageModeOn），store 持久化由单测覆盖
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: 预算数字落盘（R5 P3：before/after 可比，不靠感觉）

    private func recordMeasured(_ name: String, _ seconds: TimeInterval) {
        let a = XCTAttachment(string: String(format: "%@ = %.3f s", name, seconds))
        a.name = "perf-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: 主题 chip 点击 → 保存三态行出现（无变化/已保存 均可）

    func testThemeChipTriggersSaveStateLine() throws {
        let app = launchDemo()
        openSettings(app)

        let themeGroup = group(app, "theme")
        XCTAssertTrue(scrollToElement(app, themeGroup), "theme group 定位失败")
        themeGroup.tap()   // 展开（identifier 在头行按钮上）

        // 点「跟随系统」chip（深色为默认 → 预期「无变化」；文案二态均可接受）
        // R5 P3：chip 在展开内容里 —— 展开 tap 偶发丢失（繁忙主线程）→ 未出现则重试一次
        let chip = app.buttons["跟随系统"].firstMatch
        if !chip.waitForExistence(timeout: 4) {
            themeGroup.tap()
            XCTAssertTrue(chip.waitForExistence(timeout: 4), "theme group 未展开（chip 未出现）")
        }
        XCTAssertTrue(scrollToElement(app, chip, maxSwipes: 8), "chip 定位失败")
        chip.tap()
        let state = app.descendants(matching: .any)["settings_save_state"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5), "save state line not shown")
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
