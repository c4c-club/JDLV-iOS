import XCTest

//
//  ScreenshotsUITests.swift —— P13.3 截图集走查（UI，单方法固定顺序）。
//
//  - launch -JDLV_DEMO 1 → 首启门禁「去设置」填最小 user/pass（demo 不真正连接）进主页，
//    或已配置直接就绪；
//  - 进设置 tab → ⑧ 关于 → 开启「测试图片模式（调试）」→ 断言 accessibilityIdentifier
//    "testImageModeOn" 出现（★ 铁律：截图前必须开启）；
//  - 14 张固定顺序截图（01_首页 … 14_设置数据源），每页：锚点等待 + 1.5s 骨架静置 →
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
        app.launchArguments = ["-JDLV_DEMO", "1"]
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
        field.tap()
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
            sysBack.tap()
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

    /// 切 tab（仅在 tab 根页面调用；label 容错：存在才点）
    private func openTab(_ app: XCUIApplication, _ label: String, _ route: String) {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        let btn = tabLabeled(tabBar, label, route)
        _ = tapIfExist(btn, 8)
    }

    // iOS 18.5 tab 按钮 a11y 可能以 identifier（tab_settings 等）而非中文标题暴露 → 双路匹配
    private func tabLabeled(_ tabBar: XCUIElement, _ label: String, _ route: String) -> XCUIElement {
        let byLabel = tabBar.buttons[label]
        if byLabel.exists { return byLabel }
        if tabBar.buttons["tab_" + route].exists { return tabBar.buttons["tab_" + route] }
        let n = tabBar.buttons.count
        for i in 0..<n {
            let b = tabBar.buttons.element(boundBy: i)
            if b.label.contains(label) || b.identifier.contains("tab_" + route) { return b }
        }
        return byLabel
    }

    /// 展开设置分组卡：内容探针已存在 = 已展开（折叠记忆跨启动持久，两种状态都要能走）
    private func expandSettingsCard(_ app: XCUIApplication, _ key: String, _ probe: XCUIElement) {
        let card = app.descendants(matching: .any)["settings_group_\(key)"].firstMatch
        guard card.waitForExistence(timeout: 5) else { return }
        if probe.exists { return }
        card.tap()                                  // 收起态：点卡头展开
        if !probe.waitForExistence(timeout: 3) {
            card.tap()                              // 兜底：二次点击（防误判已展开再收起）
        }
    }

    // MARK: - 主走查（单方法固定顺序）

    func testScreenshotWalkthrough14Pages() throws {
        let app = launchDemo()

        // 0) 门禁：首启引导「去设置」→ 填最小数据源（任意非空 user/pass，demo 不真正连接，
        //    改完自动保存 800ms 防抖 → setupRequired 转 false 直接进主页）；已配置则直接就绪
        let goSettings = app.buttons["first_run_go_settings"]
        if goSettings.waitForExistence(timeout: 8) {
            goSettings.tap()
            _ = typeInto(app.textFields["用户名"], "demo")
            _ = typeInto(app.secureTextFields["密码"], "demo123")
        }
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20), "tab bar not found (gate not passed)")

        // 1) 进设置 → ⑧ 关于 → 开启「测试图片模式（调试）」→ ★ 铁律断言
        openTab(app, "设置", "settings")
        let settingsPage = app.descendants(matching: .any)["settings_page"].firstMatch
        XCTAssertTrue(settingsPage.waitForExistence(timeout: 10), "settings page not found")

        let aboutCard = app.descendants(matching: .any)["settings_group_about"].firstMatch
        scrollUntilVisible(app, aboutCard)
        let testimgSwitch = app.descendants(matching: .any)["about_testimg_switch"].firstMatch
        if !testimgSwitch.exists {
            _ = tapIfExist(aboutCard, 3)            // 收起态 → 点卡头展开
            scrollUntilVisible(app, testimgSwitch)
        }
        if testimgSwitch.exists {
            testimgSwitch.tap()
        }

        // ★ P13 截图前置锚点（铁律）：测试图片模式开启即出现
        let anchor = app.descendants(matching: .any)["testImageModeOn"].firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 6), "testImageModeOn anchor not found")

        let homePush = app.descendants(matching: .any)["home_push_movie"].firstMatch
        let entryArticles = app.descendants(matching: .any)["entry_articles"].firstMatch
        let entryHot = app.descendants(matching: .any)["entry_hotreviews"].firstMatch

        // 01_首页（搜索 tab 首页三段态：🆕最近更新 / 🔥最多想看 / 🏆TOP250 + 资讯/热评入口）
        // 锚点只放内容元素（tab bar 恒存在，会短路骨架等待）；超时兜底照常截图
        openTab(app, "搜索", "search")
        snapPage(app, "01_首页", [homePush, entryArticles], timeout: 15)

        // 02_搜索结果（搜索框输入"演示"，demo 广口径全命中；入口行消失 = 结果态到位）
        let searchField = app.textFields.firstMatch
        _ = typeInto(searchField, "演示")
        waitGone(entryArticles, 12)
        Thread.sleep(forTimeInterval: 1.5)
        snap(app, "02_搜索结果")

        // —— 中途重启一次：清搜索态（items 不随清空关键词复位，资讯/热评入口只在
        //    items == nil 渲染）；testImgMode 已落盘持久，无需重开开关 ——
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "relaunch: no tab bar")

        // 03_浏览（浏览 tab 网格）
        openTab(app, "浏览", "browse")
        let browseGrid = app.descendants(matching: .any)["browse_grid"].firstMatch
        snapPage(app, "03_浏览", [browseGrid])

        // 04_筛选面板（浏览 toolbar 筛选按钮 → 顶部下拉弹层；"展开全部" 为面板内独有按钮）
        let filterButton = app.descendants(matching: .any)["browse_filter_button"].firstMatch
        if tapIfExist(filterButton) {
            let expandAll = app.buttons["展开全部"]
            _ = expandAll.waitForExistence(timeout: 5)
            Thread.sleep(forTimeInterval: 1.5)
            snap(app, "04_筛选面板")
            // 点外关闭（弹层近透明底覆盖全屏 → 点底部空白区触发 onDismiss）
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // 05_影片详情（首页第一张影片卡 push → secondary_page）
        openTab(app, "搜索", "search")
        _ = popUntil(app, homePush, maxPops: 2)
        if tapIfExist(homePush, 8) {
            let secondary = app.descendants(matching: .any)["secondary_page"].firstMatch
            snapPage(app, "05_影片详情", [secondary])
            navBack(app)
            _ = homePush.waitForExistence(timeout: 8)
        }

        // 06_女优列表（女优 tab；demo 数据名 "演示女优 NNN" / "演示男优 NNN"）
        openTab(app, "女优", "actors")
        let actorsBar = app.descendants(matching: .any)["actors_searchbar"].firstMatch
        let actorCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "演示")).firstMatch
        snapPage(app, "06_女优列表", [actorsBar, actorCard])

        // 07_女优详情（列表第一格 push → secondary_page）
        if tapIfExist(actorCard, 8) {
            let secondary = app.descendants(matching: .any)["secondary_page"].firstMatch
            snapPage(app, "07_女优详情", [secondary])
            navBack(app)
        }

        // 08_98t 列表（98t tab 网格）
        openTab(app, "98t", "sht")
        let shtGrid = app.descendants(matching: .any)["sht_grid"].firstMatch
        snapPage(app, "08_98t列表", [shtGrid])

        // 09_帖子详情（98t 第一行 push；demo 帖子名 "演示帖子 NNN"）
        let shtCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "演示帖子")).firstMatch
        if tapIfExist(shtCard, 8) {
            let threadNav = app.navigationBars["帖子详情"]
            let threadTitle = app.staticTexts["帖子详情"]
            snapPage(app, "09_帖子详情", [threadNav, threadTitle])
            navBack(app)
        }

        // 10_资讯（首页顶部"资讯"入口 push → 列表）
        openTab(app, "搜索", "search")
        _ = popUntil(app, entryArticles)
        if tapIfExist(entryArticles, 6) {
            let articlesPage = app.descendants(matching: .any)["articles_page"].firstMatch
            snapPage(app, "10_资讯", [articlesPage])
            navBack(app)
        }

        // 11_热评（首页"热评"入口 push）
        _ = popUntil(app, entryHot)
        if tapIfExist(entryHot, 6) {
            let hotPage = app.descendants(matching: .any)["hotreviews_page"].firstMatch
            snapPage(app, "11_热评", [hotPage])
            navBack(app)
        }

        // 12_TOP250（首页 TOP250 段头"查看全部" push；段头在第三段 → 先下滑到可见）
        openTab(app, "搜索", "search")
        _ = popUntil(app, entryArticles)
        let viewAllTop = app.descendants(matching: .any)["viewall_top"].firstMatch
        scrollUntilVisible(app, viewAllTop)
        if tapIfExist(viewAllTop, 4) {
            let topPage = app.descendants(matching: .any)["top250_page"].firstMatch
            snapPage(app, "12_TOP250", [topPage])
            navBack(app)   // 自绘顶栏（导航栏隐藏）→ helper 内回落 buttons["返回"]
        }

        // 13_收藏（收藏 tab；demo 收藏空 → 空态亦为有效截图）
        openTab(app, "收藏", "favs")
        let favsPage = app.descendants(matching: .any)["tab_root_favs"].firstMatch
        snapPage(app, "13_收藏", [favsPage])

        // 14_设置数据源（设置 tab ① 数据源卡展开；折叠记忆持久 → 先探针后点卡头）
        openTab(app, "设置", "settings")
        _ = settingsPage.waitForExistence(timeout: 10)
        expandSettingsCard(app, "db", app.buttons["测试连接"])
        Thread.sleep(forTimeInterval: 1.5)
        snap(app, "14_设置数据源")

        // 每页截图必须有 attachment：14 页至少产出 12 张（铁律外的最小化断言）
        XCTAssertGreaterThanOrEqual(snapCount, 12, "screenshot set incomplete: \(snapCount)")
    }

    // iOS 18.5 模拟器 tab 按钮的 label/identifier 偶发不等于标题 → label 直查 + 全量索引扫描双路
    private func tabLabeled(_ tabBar: XCUIElement, _ label: String) -> XCUIElement {
        let byLabel = tabBar.buttons[label]
        if byLabel.exists { return byLabel }
        let n = tabBar.buttons.count
        for i in 0..<n {
            let b = tabBar.buttons.element(boundBy: i)
            if b.label.contains(label) || b.identifier.contains(label) { return b }
        }
        return byLabel
    }

    private func tabExists(_ tabBar: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
        let byLabel = tabBar.buttons[label]
        if byLabel.waitForExistence(timeout: timeout) { return true }
        for _ in 0..<6 {
            let n = tabBar.buttons.count
            for i in 0..<n {
                let b = tabBar.buttons.element(boundBy: i)
                if b.label.contains(label) || b.identifier.contains(label) { return true }
            }
            usleep(500_000)
        }
        return false
    }
}
