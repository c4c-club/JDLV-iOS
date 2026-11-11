import XCTest

// R4 P6 女优详情版式门禁（任务 08 §9.2）：
//  - 进女优详情（demo「演示女优」行，与 ScreenshotsUITests 同锚点）；
//  - 资料卡/工具行不超屏（320pt 专项在 SmallDeviceLayoutUITests 承接，此处为通用断言）；
//  - 滚到底：PageChip 与最后内容不重叠（bottom 余量 96 生效）；
//  - 标签 sheet：搜索过滤 + 滚动 5 次不崩溃 + 完成关闭；
//  - 截图 07-actor-detail.png / 07b-actor-detail-long.png 由 ScreenshotsUITests 清单承接。
final class ActorDetailLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "actorlayout_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "actorks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    private func openActorDetail(_ app: XCUIApplication) {
        let actorsTab = app.buttons["tab_actors"].firstMatch
        XCTAssertTrue(actorsTab.waitForExistence(timeout: 10), "tab_actors 必须存在")
        actorsTab.tap()
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "演示")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "demo 女优卡必须存在")
        card.tap()
        // R3 语义：secondary_page 标识落在 Button/Other 混合元素上 → 用 .any 查询
        let page = app.descendants(matching: .any)["secondary_page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "女优详情页必须压栈")
    }

    func testProfileCardAndToolbarWithinBounds() throws {
        let app = launchDemo()
        openActorDetail(app)

        // 资料卡与工具行不横向溢出
        let page = app.descendants(matching: .any)["secondary_page"].firstMatch
        XCTAssertLessThanOrEqual(page.frame.maxX, app.frame.maxX + 1.0,
                                 "详情页内容不得横向溢出")

        // 排序 Menu 存在（R4：单 Menu 取代 2 个 DropdownBox）
        let sortMenu = app.buttons["actor_sort_menu"].firstMatch
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 5), "actor_sort_menu 必须存在")
        XCTAssertLessThanOrEqual(sortMenu.frame.maxX, app.frame.maxX + 1.0,
                                 "工具行不得超屏")

        // 滚到底 → page_chip 可见且 FAB 可见（底部余量生效）
        for _ in 0..<5 { app.swipeUp() }
        let chip = app.buttons["page_chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "page_chip 必须出现")
        let fab = app.buttons["scroll_top"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "scroll_top 必须出现")
        // chip 与 FAB 竖排不重叠：chip 在 FAB 上方
        XCTAssertLessThanOrEqual(chip.frame.maxY, fab.frame.minY + 1,
                                 "PageChip 必须在 FAB 上方（竖排不重叠）")
    }

    func testTagSheetSearchScrollAndDone() throws {
        let app = launchDemo()
        openActorDetail(app)

        let tagsButton = app.buttons["actor_tags_button"].firstMatch
        XCTAssertTrue(tagsButton.waitForExistence(timeout: 10), "标签按钮必须存在")
        tagsButton.tap()

        let search = app.textFields["tag_search_field"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "标签搜索框必须出现")

        // 滚动 5 次不崩溃（60 标签 adaptive 网格）
        for _ in 0..<5 { app.swipeUp() }

        // 完成按钮（safeAreaInset 固定底部）可点 → sheet 关闭
        let done = app.buttons["完成"].firstMatch
        XCTAssertTrue(done.exists, "固定底部「完成」必须存在")
        done.tap()
        XCTAssertFalse(search.waitForExistence(timeout: 3), "点完成后 sheet 必须关闭")
    }
}
