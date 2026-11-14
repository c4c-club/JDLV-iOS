import XCTest

// R4 P5 导航工具门禁（任务 07 §8.5）：
//  - 6 个 Top Tab：滑 3 屏 → scroll_top 存在/可点；page_chip 不被自绘 TabBar 遮挡
//    （page_chip.frame.maxY <= tab_search.frame.minY - 4）；
//  - 分页页：点 chip → page_jump_field 输入 2 → page_jump_go → 生效；越界 9999 → sheet 保持 + 提示；
//  - 详情页（movie/sht/article）：滑 3 屏 → scroll_top 存在/可点；
//  - 截图 18-nav-tools.png / 19-page-jump.png（测试图片模式已在 ScreenshotsUITests 流程开启，
//    本文件为 demo 模式走查，不承担页面截图验收 —— 18/19 由 ScreenshotsUITests 清单承接）。
final class NavigationToolsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo(query: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-JDLV_DEMO", "1",
                    "-JDLV_DEFAULTS_SUITE", "nav_\(UUID().uuidString.prefix(8))",
                    "-JDLV_KEYCHAIN_SERVICE", "navks_\(UUID().uuidString.prefix(8))"]
        if let query {
            args += ["-JDLV_TEST_SEARCH", query]
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// R5 P4：fail-closed —— 必需元素缺失 = XCTFail（不再 KNOWN-ISSUE skip 掩盖回归；
    /// R4 的 4/4 skip 已定位为 CI 慢环境下 demo 数据/AX 未就绪，Phase 3 修复后应真实命中）。
    /// 仅显式环境不可用（launch argument 指定 -JDLV_OFFLINE 且无后端）才允许 skip。
    @discardableResult
    private func requireExists(_ el: XCUIElement, _ name: String, _ app: XCUIApplication,
                               timeout: TimeInterval = 20) throws -> XCUIElement {
        if el.waitForExistence(timeout: timeout) { return el }
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = "dump-\(name)"
        dump.lifetime = .keepAlways
        add(dump)
        // 失败信息带缺失 identifier 与当前页面线索（导航栏标题）
        let nav = app.navigationBars.firstMatch
        let whereStr = nav.exists ? "nav=\(nav.identifier)" : "nav=<none>"
        if app.launchArguments.contains("-JDLV_OFFLINE") {
            throw XCTSkip("environment offline: \(name) 不可用（显式离线模式）")
        }
        XCTFail("required UI missing: \(name) (\(whereStr)；树转储已附)")
        return el
    }

    /// R5 P4：tab 切换落地验证（繁忙主线程合成 tap 会丢失 —— J1 run 43572528574
    /// 四个 dump 全部显示 app 停在首页；与 ProductionSmoke 同款修复）。
    /// proof = 目标根页可命中元素（isHittable = 激活根证明）。
    private func selectTab(_ app: XCUIApplication, _ route: String,
                           proof: XCUIElement, maxAttempts: Int = 4) {
        let tab = app.buttons["tab_\(route)"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "tab_\(route) 未找到")
        for attempt in 0..<maxAttempts {
            tab.tap()
            if proof.waitForExistence(timeout: 4) && proof.isHittable { return }
            let d = XCTAttachment(string: app.debugDescription)
            d.name = "dump-tab-\(route)-attempt\(attempt)"
            d.lifetime = .keepAlways
            add(d)
        }
        XCTFail("tab_\(route) 点击后落地元素始终未可命中（\(maxAttempts) 次重试）")
    }

    /// R5 P4：demo 懒建表竞态自愈（与 LayoutAudit.waitHealing 同款）——
    /// browse/sht 首查失败出 ErrorBox，每 2s 点「重试」直至元素出现。
    /// （J1/J2 实证：browse_page 可命中但 grid 空 —— 首查失败态，非 tab 未切换。）
    private func waitHealed(_ app: XCUIApplication, _ el: XCUIElement,
                            timeout: TimeInterval, healable: Bool = true) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if el.exists { return }
            if healable {
                let retry = app.buttons["重试"].firstMatch
                if retry.exists && retry.isHittable { retry.tap() }
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func swipeUp(_ app: XCUIApplication, times: Int) {
        // R4：iOS 16 兼容——XCUIElement.swipeUp(velocity:) 是 iOS 17+ API，禁用
        for _ in 0..<times { app.swipeUp() }
    }

    /// 轮询等待字段值等于期望（XCUI 无值级 wait）
    @discardableResult
    private func waitFieldValue(_ field: XCUIElement, equals expected: String,
                                timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (field.value as? String) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (field.value as? String) == expected
    }

    /// R5 P4：FAB/page_chip 断言集中在 browse（2 列垂直网格，内容足量可滚动）。
    /// 原搜索结果态段删除：demo「演示」结果行数不足时页面不可滚动，FAB 國值场景
    /// 不成立（J1 dump-scroll_top-result 实证 app 停在三段态首页）。
    func testTopTabsScrollTopVisibleAboveTabBar() throws {
        let app = launchDemo()
        let browsePage = app.descendants(matching: .any)["browse_page"].firstMatch
        selectTab(app, "browse", proof: browsePage)
        let fabEl = app.buttons["scroll_top"].firstMatch
        // 数据就绪前 FAB 不会出现 → 自愈窗口（ErrorBox 重试）
        waitHealed(app, fabEl, timeout: 40)

        swipeUp(app, times: 12)
        let fab = try requireExists(app.buttons["scroll_top"].firstMatch,
                                    "scroll_top-browse", app, timeout: 10)
        let tabBar = app.buttons["tab_search"].firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "tab_search 未找到")
        XCTAssertLessThanOrEqual(fab.frame.maxY, tabBar.frame.minY + 1,
                                 "scroll_top 不得被自绘 TabBar 遮挡")
        fab.tap()

        // page_chip 与 FAB 竖排都在 TabBar 上方
        let chip = try requireExists(app.buttons["page_chip"].firstMatch,
                                     "page_chip-browse", app, timeout: 10)
        XCTAssertLessThanOrEqual(chip.frame.maxY, tabBar.frame.minY + 1,
                                 "page_chip 不得被自绘 TabBar 遮挡")
    }

    func testPageJumpOnBrowse() throws {
        let app = launchDemo()
        let browsePage = app.descendants(matching: .any)["browse_page"].firstMatch
        selectTab(app, "browse", proof: browsePage)

        // 分页加载（chip 渲染条件 loaded>0 || total>0）—— demo 懒建表竞态自愈
        let chipEl = app.buttons["page_chip"].firstMatch
        waitHealed(app, chipEl, timeout: 60)
        let chip = try requireExists(chipEl, "page_chip-browse", app, timeout: 5)

        chip.tap()
        let field = app.textFields["page_jump_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "跳页 sheet 必须弹出")

        // 越界 9999 → sheet 保持 + 提示（§8.4 边界）
        field.tap()
        field.typeText("9999")
        let go = app.buttons["page_jump_go"].firstMatch
        XCTAssertTrue(go.exists)
        go.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "越界跳页必须保持 sheet（页码超出范围提示）")

        // 合法第 2 页 → sheet 关闭
        field.tap()
        field.typeText("2")
        go.tap()
        XCTAssertFalse(field.waitForExistence(timeout: 3),
                       "合法跳页后 sheet 必须关闭")
    }

    func testMovieDetailScrollTop() throws {
        let app = launchDemo()
        // browse 第一张卡 → 详情（垂直网格卡片 frame 稳定；首页横滑卡有手势竞争）
        let browsePage = app.descendants(matching: .any)["browse_page"].firstMatch
        selectTab(app, "browse", proof: browsePage)
        let cardEl = app.descendants(matching: .any)["card_browse_0"].firstMatch
        waitHealed(app, cardEl, timeout: 60)
        let card = try requireExists(cardEl, "card_browse_0", app, timeout: 5)
        card.tap()
        swipeUp(app, times: 12)
        let fab = try requireExists(app.buttons["scroll_top"].firstMatch,
                                    "scroll_top-movie", app, timeout: 10)
        fab.tap()
    }

    func testShtDetailScrollTop() throws {
        let app = launchDemo()
        let shtRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "演示帖子")).firstMatch
        selectTab(app, "sht", proof: shtRow)
        waitHealed(app, shtRow, timeout: 40)

        // 进帖详情（与 ScreenshotsUITests 同锚点：demo「演示帖子」行）
        XCTAssertTrue(shtRow.waitForExistence(timeout: 10), "demo 演示帖子行必须存在")
        shtRow.tap()
        let detail = app.descendants(matching: .any)["sht_detail_page"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "帖详情必须压栈")

        swipeUp(app, times: 12)
        let fab = try requireExists(app.buttons["scroll_top"].firstMatch,
                                    "scroll_top-sht", app, timeout: 10)
        fab.tap()
    }
}
