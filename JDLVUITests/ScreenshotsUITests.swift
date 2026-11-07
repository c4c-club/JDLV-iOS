import XCTest

//
//  ScreenshotsUITests.swift —— P13.3 截图集走查（UI，单方法固定顺序）。
//
//  - launch -JDLV_DEMO 1 → 首启门禁「去设置」填最小 user/pass（demo 不真正连接）进主页，
//    或已配置直接就绪；
//  - 进设置 tab → ⑧ 关于 → 开启「测试图片模式（调试）」→ 断言 accessibilityIdentifier
//    "testImageModeOn" 出现（★ 铁律：截图前必须开启）；
//  - 14 张固定顺序截图（01-home … 14-settings-data），每页：锚点等待 + 1.5s 骨架静置 →
//    XCTAttachment(lifetime: .keepAlways, name: "NN_页面名") → add；
//  - 断言最少化：testImageModeOn + 末尾截图数 ≥ 12；其余交互一律 if-exists 守卫
//    （元素不存在走 fallback 路径，绝不 force tap 不存在元素），保证截图集尽量完整；
//  - 中途一次 app 重启（02 之后）：清掉搜索态（清空关键词不会复位 items，资讯/热评
//    入口行只在 items == nil 渲染），重启后 testImgMode 已落盘持久，无需重开开关。
//
final class ScreenshotsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var snapCount = 0

    // MARK: - Helpers

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        // A9/R8：独立 defaults suite + 独立 Keychain service（防 testImgMode 等跨用例持久污染）
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    /// 截图统一 helper：keepAlways + 固定命名（NN_页面名）
    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        snapCount += 1
    }

    /// 存在性等待 helper
    @discardableResult
    private func waitFor(_ el: XCUIElement, _ timeout: TimeInterval) -> Bool {
        el.waitForExistence(timeout: timeout)
    }

    /// 任一锚点出现即返回（骨架消失的替身信号：锚点 = 内容元素，非骨架元素）
    @discardableResult
    private func waitForAny(_ els: [XCUIElement], _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for e in els where e.exists { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return els.contains { $0.exists }
    }

    /// 等元素消失（搜索结果态检测：入口行只在 items == nil 渲染）
    @discardableResult
    private func waitGone(_ el: XCUIElement, _ timeout: TimeInterval) -> Bool {
        guard el.exists else { return true }
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == 0"), object: el)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    /// 每页截图：锚点等待（骨架消失）→ 1.5s 静置 → snap
    private func snapPage(_ app: XCUIApplication, _ name: String,
                          _ anchors: [XCUIElement], timeout: TimeInterval = 12) {
        waitForAny(anchors, timeout)
        Thread.sleep(forTimeInterval: 1.5)
        snap(app, name)
    }

    /// 存在才点（存在但不 hittable → 用中心坐标兜底，绝不点不存在的元素）
    @discardableResult
    private func tapIfExist(_ el: XCUIElement, _ timeout: TimeInterval = 4) -> Bool {
        guard el.waitForExistence(timeout: timeout) else { return false }
        if el.isHittable {
            el.tap()
        } else {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    /// 文本输入（tap 聚焦后 typeText；键盘异常不致命 → 返回 false 走后续守卫）
    @discardableResult
    private func typeInto(_ field: XCUIElement, _ text: String) -> Bool {
        guard field.waitForExistence(timeout: 6) else { return false }
        if field.isHittable {
            field.tap()
        } else {
            // 元素存在但不可点（横幅/底栏遮挡）→ 用自身 frame 中心坐标兜底
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        do {
            try field.typeText(text)
            return true
        } catch {
            return false
        }
    }

    /// 返回上一页：系统 nav bar 返回键优先；Top250 自绘顶栏（导航栏隐藏）→ "返回" 按钮
    private func navBack(_ app: XCUIApplication) {
        let sysBack = app.navigationBars.buttons.firstMatch
        if sysBack.waitForExistence(timeout: 3) {
            // 页面转场动画中 AX tap 可能报 scroll-to-visible 失败 → 等 hittable 再点；
            // 仍不可点（转场未结束）→ 用 frame 中心坐标兜底
            var i = 0
            while !sysBack.isHittable, i < 8 { usleep(250_000); i += 1 }
            if sysBack.isHittable {
                sysBack.tap()
            } else {
                sysBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
        _ = tapIfExist(app.buttons["返回"], 2)   // Top250 自绘返回（accessibilityLabel 逐字）
    }

    /// 逐层返回直到锚点可见（push 栈残留容错，最多 maxPops 次）
    @discardableResult
    private func popUntil(_ app: XCUIApplication, _ anchor: XCUIElement, maxPops: Int = 4) -> Bool {
        var i = 0
        while !(anchor.exists && anchor.isHittable) && i < maxPops {
            navBack(app)
            Thread.sleep(forTimeInterval: 0.8)
            i += 1
        }
        return anchor.exists
    }

    /// 下滑直到元素可点（设置页/首页段头下沉用）
    private func scrollUntilVisible(_ app: XCUIApplication, _ el: XCUIElement, maxSwipes: Int = 14) {
        var i = 0
        while !(el.exists && el.isHittable) && i < maxSwipes {
            app.swipeUp()
            i += 1
        }
    }


    // MARK: P13.3 主走查：测试图片模式先开 → 14 页截图（每页 keepAlways 附件）

    func testScreenshotWalkthrough14Pages() throws {
        let app = launchDemo()

        // 0) 门禁：demo 模式直接进主页（AppGate 跳过首启门禁）
        let tabBarBtn = app.buttons["tab_search"]
        XCTAssertTrue(tabBarBtn.waitForExistence(timeout: 20), "tab bar not found (gate not passed)")

        // 1) 设置 → ⑧ 关于 → 开启「测试图片模式（调试）」→ ★ 铁律断言
        openTab(app, "设置", "settings")
        let settingsPage = app.descendants(matching: .any)["settings_page"].firstMatch
        XCTAssertTrue(settingsPage.waitForExistence(timeout: 10), "settings page not found")

        let aboutGroup = app.descendants(matching: .any)["settings_group_about"].firstMatch
        scrollUntilVisible(app, aboutGroup, maxSwipes: 12)
        // CollapsiblePref 记忆展开态（前序用例可能已展开）→ 先探 switch
        var sw = app.descendants(matching: .any)["about_testimg_switch"].firstMatch
        if !sw.waitForExistence(timeout: 3) {
            aboutGroup.tap()   // 收起中 → 切换展开
            _ = waitUntilShort(3) { sw.exists }
        }
        XCTAssertTrue(sw.waitForExistence(timeout: 5), "about_testimg_switch not found")
        // About 是最后一卡：滚动到"行位于屏幕上半部"（确定可见、且在自绘底栏之上）
        var si = 0
        while si < 30 {
            let f = sw.frame
            let screenH = app.frame.height
            if sw.exists, sw.isHittable, f.minY < screenH * 0.5 { break }
            app.swipeUp()
            si += 1
        }
        XCTAssertTrue(sw.isHittable, "about switch not hittable after scrolling")
        // 目标 = testImageModeOn 锚点可见；点击行内 Toggle（identifier switch_<label>），
        // 不中则点行按钮；锚点出现即停（≤4 次）
        let anchor = app.descendants(matching: .any)["testImageModeOn"].firstMatch
        // AppSwitchRow 内层 Toggle 带 identifier switch_<label>（Controls.swift）→ 直点开关本体
        let innerToggle = app.switches["switch_测试图片模式（调试）"].firstMatch
        var anchorOn = anchor.exists
        for _ in 0..<4 {
            if anchor.exists { anchorOn = true; break }
            if innerToggle.exists, innerToggle.isHittable {
                innerToggle.tap()
            } else if sw.isHittable {
                sw.tap()
            } else {
                sw.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if anchor.waitForExistence(timeout: 3) { anchorOn = true; break }
        }
        if !anchorOn {
            // 诊断：挂截图 + 全部 switch 元素 dump
            let diag = XCTAttachment(screenshot: app.screenshot())
            diag.name = "diag_anchor_missing"
            diag.lifetime = .keepAlways
            add(diag)
            var dump = "switches: "
            let n = app.switches.count
            for i in 0..<min(n, 30) {
                let b = app.switches.element(boundBy: i)
                dump += "[\(i)] id='\(b.identifier)' label='\(b.label)' value='\(b.value as? String ?? "?")' hittable=\(b.isHittable); "
            }
            let d2 = XCTAttachment(string: dump)
            d2.name = "diag_switches_dump"
            d2.lifetime = .keepAlways
            add(d2)
        }
        XCTAssertTrue(anchorOn, "testImageModeOn anchor not found after toggle attempts")
        snap(app, "00-test-image-mode-on")

        // 2) 14 页走查
        openTab(app, "搜索", "search")
        snapPage(app, "01-home", [app.buttons["entry_articles"], app.buttons["entry_hotreviews"],
                                  app.buttons["viewall_recent"]])

        // 搜索态（搜索框被横幅/键盘遮挡时退化为首页态截图）
        let field = app.textFields.firstMatch
        if field.exists, field.isHittable {
            _ = typeInto(field, "演示")
        }
        snapPage(app, "02-search-results", [app.buttons["mode_fuzzy"], app.buttons["mode_exact"]])
        app.terminate()
        app.launch()

        openTab(app, "浏览", "browse")
        snapPage(app, "03-browse", [app.buttons["sht_filter_button"], app.buttons["browse_grid"],
                                  app.buttons["tab_browse"]])
        let filterBtn = app.buttons["sht_filter_button"]
        _ = tapResilient(filterBtn)
        snap(app, "04-filter-panel")
        _ = tapResilient(filterBtn)   // 关面板（toggle）

        openTab(app, "搜索", "search")
        let push = app.descendants(matching: .any)["home_push_movie"].firstMatch
        if push.waitForExistence(timeout: 12) {
            // 横滑段首卡可能被滑出屏幕左侧（frame.minX < 0）→ 右滑拉回
            if !push.isHittable { app.swipeRight() }
            _ = tapResilient(push)
            snapPage(app, "05-movie-detail", [app.descendants(matching: .any)["secondary_page"].firstMatch])
            navBack(app)
        }

        openTab(app, "女优", "actors")
        // demo 模式所有女优卡 label 含"演示" → 无需搜索；搜索框可能被横幅遮挡（不 hittable）→ 跳过输入
        snapPage(app, "06-actors", [app.descendants(matching: .any)["tab_root_actors"].firstMatch])
        let actorCard = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "演示")).firstMatch
        if actorCard.exists {
            _ = tapResilient(actorCard)
            snapPage(app, "07-actor-detail", [app.descendants(matching: .any)["secondary_page"].firstMatch])
            navBack(app)
        }

        openTab(app, "98t", "sht")
        snapPage(app, "08-sht", [app.descendants(matching: .any)["sht_filter_button"].firstMatch])
        let shtRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "演示帖子")).firstMatch
        if shtRow.exists {
            _ = tapResilient(shtRow)
            snapPage(app, "09-thread-detail", [app.navigationBars.firstMatch,
                                          app.descendants(matching: .any)["secondary_page"].firstMatch])
            navBack(app)
        }

        openTab(app, "搜索", "search")
        let entryArticles = app.buttons["entry_articles"]
        if entryArticles.waitForExistence(timeout: 8) {
            _ = tapResilient(entryArticles)
            snapPage(app, "10-articles", [app.descendants(matching: .any)["articles_page"].firstMatch])
            navBack(app)
        }
        let entryHot = app.buttons["entry_hotreviews"]
        if entryHot.exists {
            _ = tapResilient(entryHot)
            snapPage(app, "11-hot-reviews", [app.descendants(matching: .any)["hotreviews_page"].firstMatch])
            navBack(app)
        }
        let viewallTop = app.buttons["viewall_top"]
        if viewallTop.exists {
            _ = tapResilient(viewallTop)
            snapPage(app, "12-top250", [app.descendants(matching: .any)["top250_page"].firstMatch])
            navBack(app)
        }

        openTab(app, "收藏", "favs")
        snapPage(app, "13-favs", [app.descendants(matching: .any)["tab_root_favs"].firstMatch])

        openTab(app, "设置", "settings")
        let dbGroup = app.descendants(matching: .any)["settings_group_db"].firstMatch
        scrollUntilVisible(app, dbGroup, maxSwipes: 12)
        snapPage(app, "14-settings-data", [dbGroup])

        XCTAssertGreaterThanOrEqual(snapCount, 12, "expected ≥12 screenshots, got \(snapCount)")
    }


    private func waitUntilShort(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            usleep(200_000)
        }
        return cond()
    }

    /// 切 tab（仅在 tab 根页面调用；label 容错：存在才点）
    private func openTab(_ app: XCUIApplication, _ label: String, _ route: String) {
        let btn = tabLabeled(app, label, route)
        _ = tapIfExist(btn, 10)
    }


    // 自绘底栏按钮：identifier tab_<route>（iOS 18.5 无系统 tab bar）→ 双路查找
    // 自绘底栏按钮：identifier tab_<route>（iOS 18.5 无系统 tab bar）→ 双路查找
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

    /// 遮挡容错点击：hittable → 直接点；否则等待 1.5s 重试（toast/横幅消退）→ 坐标兜底
    @discardableResult
    private func tapResilient(_ el: XCUIElement, attempts: Int = 3) -> Bool {
        for i in 0..<attempts {
            guard el.exists else { return false }
            if el.isHittable {
                el.tap()
                return true
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard el.exists else { return false }
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }
}
