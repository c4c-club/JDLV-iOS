import XCTest

/// R6 PHASE3：98t 主版筛选「有选项且可点选」UI 出口测试（任务 04）。
/// VM 层断言（选项>0、setMain 查询参数、兜底可点选）在 ShtVMTests；
/// 本测试验证真实 sheet 渲染与点选链路（点开 Picker → 选项行 → 回选 → 关闭）。
final class ShtFilterSheetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testShtFilterSheetMainOptionsExistAndSelectable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()

        let shtTab = app.buttons["tab_sht"].firstMatch
        XCTAssertTrue(shtTab.waitForExistence(timeout: 20), "tab bar not found")
        if shtTab.isHittable {
            shtTab.tap()
        } else {
            shtTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let grid = app.descendants(matching: .any)["sht_grid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 60), "98t grid not rendered")

        app.buttons["sht_filter_button"].firstMatch.tap()
        let mainPicker = app.descendants(matching: .any)["sht_main_picker"].firstMatch
        XCTAssertTrue(mainPicker.waitForExistence(timeout: 15), "筛选 sheet 未渲染主版 Picker")

        // 选项 > 0 且可点选：Form 内 Picker（iPhone 默认 nav 风格）点开 → 选项行出现。
        // CI demo 走远程分类（shtCategories mock 对位 demo 聚合，首行 = 有码中文字幕）。
        mainPicker.tap()
        let option = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "有码中文字幕")).firstMatch
        if option.waitForExistence(timeout: 8) {
            option.tap()
        } else {
            // nav 风格在不同 OS 上呈现差异：选项行可能是静态文本/other 节点
            let alt = app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", "有码中文字幕")).firstMatch
            XCTAssertTrue(alt.waitForExistence(timeout: 8), "主版选项未出现（选项数=0 的旧缺陷）")
            alt.tap()
        }

        let done = app.buttons["sht_filter_done"].firstMatch
        if done.waitForExistence(timeout: 6) {
            done.tap()
        } else {
            app.swipeDown(velocity: .fast)   // 兜底关 sheet
        }
        XCTAssertTrue(app.descendants(matching: .any)["sht_grid"].firstMatch
            .waitForExistence(timeout: 10), "关闭 sheet 后列表未恢复")
    }


    /// R7 P4：连续 6 次筛选切换，每次断言非纯空白 —— searchBar 恒在（页面结构没塌）
    /// 且（首卡 或 空态+重置按钮）可见（任务 05 步骤 6 / 出口检查 3）。
    @MainActor
    func testShtNeverBlankAfterFilterChange() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()

        let shtTab = app.buttons["tab_sht"].firstMatch
        XCTAssertTrue(shtTab.waitForExistence(timeout: 20), "tab bar not found")
        if shtTab.isHittable {
            shtTab.tap()
        } else {
            shtTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["sht_grid"].firstMatch
            .waitForExistence(timeout: 60), "98t grid not rendered")

        for round in 0..<6 {
            app.buttons["sht_filter_button"].firstMatch.tap()
            let mainPicker = app.descendants(matching: .any)["sht_main_picker"].firstMatch
            XCTAssertTrue(mainPicker.waitForExistence(timeout: 15),
                          "round \(round) 筛选 sheet 未渲染主版 Picker")
            mainPicker.tap()
            let label = round % 2 == 0 ? "有码中文字幕" : "全部"
            let opt = app.buttons.containing(
                NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            if opt.waitForExistence(timeout: 8) {
                opt.tap()
            } else {
                let alt = app.descendants(matching: .any)
                    .containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
                XCTAssertTrue(alt.waitForExistence(timeout: 8),
                              "round \(round) 主版选项 \(label) 未出现")
                alt.tap()
            }
            let done = app.buttons["sht_filter_done"].firstMatch
            if done.waitForExistence(timeout: 6) {
                done.tap()
            } else {
                app.swipeDown(velocity: .fast)   // 兜底关 sheet
            }
            // 非空白断言：结构（searchBar）恒在；内容 = 首卡 或 空态+重置按钮
            XCTAssertTrue(app.descendants(matching: .any)["sht_searchbar"].firstMatch
                .waitForExistence(timeout: 10), "round \(round) 搜索条消失（页面结构塌了）")
            let hasCard = app.descendants(matching: .any)["shtcard_0"].firstMatch
                .waitForExistence(timeout: 20)
            let resetBtn = app.descendants(matching: .any)["empty_action_button"].firstMatch
            let emptyText = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "当前筛选无结果")).firstMatch
            let nonBlank = hasCard || resetBtn.waitForExistence(timeout: 2) || emptyText.exists
            XCTAssertTrue(nonBlank, "round \(round) 纯空白（无首卡也无空态出口）—— G5 复现")
        }
    }
}