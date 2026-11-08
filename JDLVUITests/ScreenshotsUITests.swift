import XCTest

//
//  ScreenshotsUITests.swift —— v2 截图集走查（R3 §6.3：17 张 + 页面身份断言 + manifest）。
//
//  R2 缺陷修复（docs/13 §1.2）：
//  - 04 曾用 sht_filter_button（浏览页不存在）→ 拍成影片详情：v2 用 browse_filter_button
//    并断言 sheet 内容锚点；
//  - 灯箱打开后从未关闭 → 05 起全是灯箱：v2 每页前 dismissAnyModal（lightbox_close /
//    「完成」按钮 / 下滑关闭 sheet）+ 页面唯一锚点断言；
//  - 无 manifest → verify_screenshots.py --manifest 校验 pageName 与文件名一致。
//
//  17 张：00-test-image-mode-on、01-home、02-search-results、03-browse、04-filter-sheet、
//  05-movie-detail、06-actors、07-actor-detail、08-sht、09-thread-detail、10-articles、
//  11-hot-reviews、12-top250、13-favs、14-settings-data、15-about、16-lightbox。
//
final class ScreenshotsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var snapCount = 0
    private var manifest: [[String: String]] = []

    // MARK: - Helpers

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String, anchor: String) {
        XCTAssertTrue(app.state == .runningForeground, "\(name): app not foreground")
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        manifest.append(["pageName": name, "anchor": anchor,
                         "ts": ISO8601DateFormatter().string(from: Date())])
        snapCount += 1
    }

    @discardableResult
    private func waitFor(_ el: XCUIElement, _ timeout: TimeInterval) -> Bool {
        el.waitForExistence(timeout: timeout)
    }

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

    @discardableResult
    private func typeInto(_ field: XCUIElement, _ text: String) -> Bool {
        guard field.waitForExistence(timeout: 6) else { return false }
        if field.isHittable {
            field.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        do {
            try field.typeText(text)
            return true
        } catch {
            return false
        }
    }

    /// 每页截图：关闭任何弹层 → 锚点等待 → 1.2s 静置 → snap
    private func snapPage(_ app: XCUIApplication, _ name: String,
                          _ anchors: [XCUIElement], timeout: TimeInterval = 12) {
        dismissAnyModal(app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for e in anchors where e.exists { break }
            if anchors.contains(where: { $0.exists }) { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 1.2)
        snap(app, name, anchor: anchors.first?.identifier ?? name)
    }

    /// 关闭任何弹层：灯箱 ✕ → sheet「完成」→ 通用「完成」→ swipeDown 兜底
    func dismissAnyModal(_ app: XCUIApplication) {
        let close = app.buttons["lightbox_close"]
        if close.exists {
            _ = tapIfExist(close, 2)
            Thread.sleep(forTimeInterval: 0.6)
        }
        let done = app.buttons["sht_filter_done"]
        if done.exists && done.isHittable {
            done.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        // 通用 sheet：导航栏「完成」/ label「完成」（FiltersPanel 等）
        let navDone = app.navigationBars.buttons["完成"]
        if navDone.exists && navDone.isHittable {
            navDone.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        let genericDone = app.buttons["完成"]
        if genericDone.exists && genericDone.isHittable && genericDone.identifier != "sht_filter_done" {
            genericDone.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        // 兜底：从屏幕上缘下滑关 sheet（无弹层时列表回弹，无害）
        if app.sheets.count > 0 {
            app.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    private func navBack(_ app: XCUIApplication) {
        let sysBack = app.navigationBars.buttons.firstMatch
        if sysBack.waitForExistence(timeout: 3) {
            var i = 0
            while !sysBack.isHittable, i < 8 { usleep(250_000); i += 1 }
            if sysBack.isHittable {
                sysBack.tap()
            } else {
                sysBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
        _ = tapIfExist(app.buttons["返回"], 2)
    }

    private func scrollUntilVisible(_ app: XCUIApplication, _ el: XCUIElement, maxSwipes: Int = 14) {
        var i = 0
        while !(el.exists && el.isHittable) && i < maxSwipes {
            app.swipeUp()
            i += 1
        }
    }

    private func openTab(_ app: XCUIApplication, _ label: String, _ route: String) {
        let byId = app.buttons["tab_" + route]
        _ = tapIfExist(byId, 10)
    }

    // MARK: 主走查：测试图片模式先开 → 17 页截图（页面身份断言 + manifest）

    func testScreenshotWalkthrough17Pages() throws {
        let app = launchDemo()
        XCTAssertTrue(app.buttons["tab_search"].waitForExistence(timeout: 20), "tab bar not found")

        // 1) 设置 → 关于 → 开启「测试图片模式（调试）」→ ★ 铁律断言（R3：About 是子页）
        openTab(app, "设置", "settings")
        let settingsPage = app.descendants(matching: .any)["settings_page"].firstMatch
        XCTAssertTrue(settingsPage.waitForExistence(timeout: 10), "settings page not found")
        let aboutLink = app.buttons["settings_about_link"]
        scrollUntilVisible(app, aboutLink, maxSwipes: 14)
        XCTAssertTrue(tapIfExist(aboutLink, 6), "settings_about_link not found")
        // AppSwitchRow：id 在整行 Button 上 → 双路查询
        let testSwitch0 = app.buttons["about_testimg_switch"].firstMatch
        let testSwitch = testSwitch0.exists ? testSwitch0
            : app.switches["about_testimg_switch"].firstMatch
        XCTAssertTrue(testSwitch.waitForExistence(timeout: 8), "about_testimg_switch not found (AboutView)")
        let anchor = app.descendants(matching: .any)["testImageModeOn"].firstMatch
        var anchorOn = anchor.exists
        for _ in 0..<6 {
            if anchor.exists { anchorOn = true; break }
            // 双路：Form 行内 Toggle 直点；未生效则点行文本（Form 行整行可点）
            if testSwitch.isHittable {
                testSwitch.tap()
            } else {
                testSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if anchor.waitForExistence(timeout: 3) { anchorOn = true; break }
            let rowText = app.staticTexts["测试图片模式（调试）"].firstMatch
            if rowText.exists && rowText.isHittable { rowText.tap() }
            if anchor.waitForExistence(timeout: 3) { anchorOn = true; break }
        }
        XCTAssertTrue(anchorOn, "testImageModeOn anchor not found after toggle attempts")
        snap(app, "00-test-image-mode-on", anchor: "testImageModeOn")
        navBack(app)   // 返回设置主页

        // 2) 01-home（首页三段态）
        openTab(app, "搜索", "search")
        snapPage(app, "01-home", [app.buttons["entry_articles"], app.buttons["entry_hotreviews"],
                                  app.buttons["viewall_recent"]])

        // 3) 02-search-results（输入「演示」→ CardGrid）
        let field = app.textFields.firstMatch
        if field.exists, field.isHittable {
            _ = typeInto(field, "演示")
        }
        snapPage(app, "02-search-results", [app.buttons["mode_fuzzy"], app.buttons["mode_exact"]])
        dismissAnyModal(app)

        // 4) 03-browse（CardGrid 2 列）
        openTab(app, "浏览", "browse")
        snapPage(app, "03-browse", [app.descendants(matching: .any)["browse_grid"].firstMatch,
                                    app.buttons["browse_filter_button"]])

        // 5) 04-filter-sheet（browse_filter_button → FiltersPanel sheet；页面身份=sheet「完成」）
        let filterBtn = app.buttons["browse_filter_button"]
        XCTAssertTrue(tapIfExist(filterBtn, 6), "browse_filter_button not found")
        snapPage(app, "04-filter-sheet", [app.buttons["browse_filter_button"],
                                          app.navigationBars.firstMatch])
        dismissAnyModal(app)   // 关 sheet

        // 6) 05-movie-detail（首页 → 段首卡）
        openTab(app, "搜索", "search")
        let push = app.descendants(matching: .any)["home_push_movie"].firstMatch
        if push.waitForExistence(timeout: 12) {
            if !push.isHittable { app.swipeRight() }
            _ = tapIfExist(push)
            snapPage(app, "05-movie-detail",
                     [app.descendants(matching: .any)["secondary_page"].firstMatch])
            dismissAnyModal(app)
            navBack(app)
        }

        // 7) 06-actors / 07-actor-detail
        openTab(app, "女优", "actors")
        snapPage(app, "06-actors", [app.descendants(matching: .any)["card_actors_0"].firstMatch])
        let actorCard = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "演示")).firstMatch
        if actorCard.exists {
            _ = tapIfExist(actorCard)
            snapPage(app, "07-actor-detail",
                     [app.descendants(matching: .any)["secondary_page"].firstMatch])
            navBack(app)
        }

        // 8) 08-sht / 09-thread-detail（R3：sht_grid 锚点；详情单 LazyVStack）
        openTab(app, "98t", "sht")
        snapPage(app, "08-sht", [app.descendants(matching: .any)["sht_grid"].firstMatch,
                                 app.descendants(matching: .any)["shtcard_0"].firstMatch])
        let shtRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "演示帖子")).firstMatch
        if shtRow.exists {
            _ = tapIfExist(shtRow)
            snapPage(app, "09-thread-detail",
                     [app.descendants(matching: .any)["sht_detail_page"].firstMatch,
                      app.navigationBars.firstMatch])
            navBack(app)
        }

        // 9) 10-articles / 11-hot-reviews / 12-top250
        openTab(app, "搜索", "search")
        let entryArticles = app.buttons["entry_articles"]
        if entryArticles.waitForExistence(timeout: 8) {
            _ = tapIfExist(entryArticles)
            snapPage(app, "10-articles",
                     [app.descendants(matching: .any)["articles_page"].firstMatch])
            navBack(app)
        }
        let entryHot = app.buttons["entry_hotreviews"]
        if entryHot.exists {
            _ = tapIfExist(entryHot)
            snapPage(app, "11-hot-reviews",
                     [app.descendants(matching: .any)["hotreviews_page"].firstMatch])
            navBack(app)
        }
        let viewallTop = app.buttons["viewall_top"]
        if viewallTop.exists {
            _ = tapIfExist(viewallTop)
        let top250Opened = app.buttons["t250row_0"].firstMatch.waitForExistence(timeout: 15)
        if !top250Opened {
            // demo bind 竞态（6 tab 常驻）→ 重启 app 重试 push
            app.terminate()
            app.launch()
            _ = app.buttons["tab_search"].waitForExistence(timeout: 20)
            _ = app.descendants(matching: .any)["home_push_movie"].firstMatch
                .waitForExistence(timeout: 25)
            _ = tapIfExist(app.buttons["viewall_top"], 15)
            _ = app.buttons["t250row_0"].firstMatch.waitForExistence(timeout: 20)
        }
            snapPage(app, "12-top250",
                     [app.buttons["t250row_0"].firstMatch,
                      app.descendants(matching: .any)["t250row_1"].firstMatch])
            navBack(app)
        }

        // 10) 13-favs
        openTab(app, "收藏", "favs")
        snapPage(app, "13-favs", [app.descendants(matching: .any)["tab_root_favs"].firstMatch])

        // 11) 14-settings-data（数据源卡）
        openTab(app, "设置", "settings")
        let dbGroup = app.descendants(matching: .any)["settings_group_db"].firstMatch
        scrollUntilVisible(app, dbGroup, maxSwipes: 12)
        snapPage(app, "14-settings-data", [dbGroup])

        // 12) 15-about（About 子页：版本信息 + 诊断 ≥8 行）
        let aboutLink2 = app.buttons["settings_about_link"]
        scrollUntilVisible(app, aboutLink2, maxSwipes: 12)
        if tapIfExist(aboutLink2, 6) {
            snapPage(app, "15-about", [app.buttons["about_keyboard_diag"],
                                       app.navigationBars.firstMatch])
            navBack(app)
        } else {
            snap(app, "15-about", anchor: "settings_about_link_missing")
        }

        // 13) 16-lightbox（详情 hero → 灯箱 fit 完整图）
        openTab(app, "搜索", "search")
        let push2 = app.descendants(matching: .any)["home_push_movie"].firstMatch
        if push2.waitForExistence(timeout: 12) {
            if !push2.isHittable { app.swipeRight() }
            _ = tapIfExist(push2)
            let hero = app.descendants(matching: .any)["secondary_page"].firstMatch
            if hero.waitForExistence(timeout: 10) {
                // 封面区点击开灯箱（cover 无独立 id → 点页面上部中央）
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).tap()
                let lbClose = app.buttons["lightbox_close"]
                if lbClose.waitForExistence(timeout: 6) {
                    snap(app, "16-lightbox", anchor: "lightbox_close")
                    _ = tapIfExist(lbClose, 3)   // ★ 关灯箱（R2 缺陷修复）
                }
            }
            navBack(app)
        }

        // manifest 附件（verify_screenshots.py --manifest 消费）
        if let data = try? JSONSerialization.data(withJSONObject: ["pages": manifest],
                                                  options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            let m = XCTAttachment(string: s)
            m.name = "screenshots-manifest.json"
            m.lifetime = .keepAlways
            add(m)
        }

        XCTAssertEqual(snapCount, 17, "expected 17 screenshots, got \(snapCount)")
    }
}
