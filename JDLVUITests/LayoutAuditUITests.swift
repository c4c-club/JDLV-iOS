import XCTest

//
//  LayoutAuditUITests.swift —— 全页面卡片布局审计（R3 §6.2；13 §2.5–2.7 验收）。
//
//  每页：收集 card_*（或行卡固定 id）元素 frame → 按 minY 分组（±1）→ 断言
//  组内等宽/等高/minY（差 ≤0.5）、相邻 minX 间距 = gridSpacing ±0.5、无重叠、
//  全部在屏幕内；列表页 swipeUp 后内容上移（可滚动）。
//  违规明细写 layout-report.json（XCTAttachment，CI verify_layout.py 消费）。
//
final class LayoutAuditUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: 报告

    private var report: [[String: Any]] = []

    private func addViolation(_ page: String, _ element: String, _ reason: String) {
        report.append(["page": page, "element": element, "violation": reason])
    }

    private func flushReport() {
        if let data = try? JSONSerialization.data(withJSONObject: ["violations": report],
                                                  options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            let a = XCTAttachment(string: s)
            a.name = "layout-report.json"
            a.lifetime = .keepAlways
            add(a)
        }
    }

    // MARK: 启动

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    private func openTab(_ app: XCUIApplication, _ route: String) {
        let btn = app.buttons["tab_" + route]
        XCTAssertTrue(btn.waitForExistence(timeout: 12), "tab_\(route) not found")
        if btn.isHittable { btn.tap() } else {
            btn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func tapIfExist(_ el: XCUIElement, _ timeout: TimeInterval = 5) -> Bool {
        guard el.waitForExistence(timeout: timeout) else { return false }
        if el.isHittable { el.tap() } else {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    // MARK: 审计核心

    private func collect(_ app: XCUIApplication, prefix: String) -> [(String, CGRect)] {
        var out: [(String, CGRect)] = []
        let q = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let n = q.count
        for i in 0..<min(n, 40) {
            let e = q.element(boundBy: i)
            if e.exists, e.frame.width > 1 {
                out.append((e.identifier, e.frame))
            }
        }
        return out
    }

    /// 分组断言：同 minY 行（±1）内等宽/等高/minY；相邻卡间距 spacing ±0.5；无重叠；不出屏
    private func audit(_ app: XCUIApplication, page: String, prefix: String,
                       columns: Int, spacing: CGFloat, checkScroll: Bool) {
        var cards = collect(app, prefix: prefix)
        if cards.isEmpty {
            addViolation(page, prefix, "no cards found")
            return
        }
        cards.sort { $0.1.minY == $1.1.minY ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }

        let screen = app.frame
        let rows = groupByRow(cards)
        // 每组数量 ≤ 列数（最后一行可少）
        for (idx, row) in rows.enumerated() {
            if row.count > columns {
                addViolation(page, "row\(idx)", "row has \(row.count) cards > expected columns \(columns)")
            }
            let widths = row.map { $0.1.width }
            let heights = row.map { $0.1.height }
            let minys = row.map { $0.1.minY }
            if let w0 = widths.first, widths.contains(where: { abs($0 - w0) > 0.5 }) {
                addViolation(page, "row\(idx)", "width mismatch: \(widths)")
            }
            if let h0 = heights.first, heights.contains(where: { abs($0 - h0) > 0.5 }) {
                addViolation(page, "row\(idx)", "height mismatch: \(heights)")
            }
            if let y0 = minys.first, minys.contains(where: { abs($0 - y0) > 1.0 }) {
                addViolation(page, "row\(idx)", "minY mismatch: \(minys)")
            }
            // 相邻 minX 间距 + 无重叠
            for j in 1..<row.count {
                let gap = row[j].1.minX - row[j - 1].1.maxX
                if gap < -0.5 {
                    addViolation(page, row[j].0, "overlap: gap=\(gap)")
                } else if abs(gap - spacing) > 1.0 {
                    addViolation(page, row[j].0, "gap \(gap) != \(spacing)±1")
                }
            }
        }
        // 出屏（允许 1pt 误差；横滑首卡可被裁 → 横滑段跳过 minX 出屏检查由调用方传 allowOffscreen）
        for c in cards {
            if c.1.minX < -1 || c.1.maxX > screen.width + 1 || c.1.minY < -1 || c.1.maxY > screen.height + 1 {
                addViolation(page, c.0, "out of screen: \(c.1)")
            }
        }
        // 可滚动：swipeUp 后最后一张 minY 上移或出现新卡
        if checkScroll, cards.count >= 2 {
            let before = cards.map { $0.1.minY }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            let after = collect(app, prefix: prefix).map { $0.1.minY }
            let moved = after.max() ?? 0 < (before.max() ?? 0) - 10
            let more = after.count > before.count
            if !moved && !more {
                addViolation(page, prefix, "not scrollable (minY unchanged, no new cards)")
            }
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private func groupByRow(_ cards: [(String, CGRect)]) -> [[(String, CGRect)]] {
        var rows: [[(String, CGRect)]] = []
        for c in cards {
            if var last = rows.last, let ly = last.first?.1.minY, abs(ly - c.1.minY) <= 1 {
                last.append(c)
                rows[rows.count - 1] = last
            } else {
                rows.append([c])
            }
        }
        return rows
    }

    // MARK: 主审计（9 页）

    func testAllPagesCardLayoutAudit() throws {
        let app = launchDemo()
        XCTAssertTrue(app.buttons["tab_search"].waitForExistence(timeout: 20))

        // 1) 首页三段横滑（160×289 单行；不查滚动 —— 段内容固定）
        audit(app, page: "home-recent", prefix: "home_recent_", columns: 6, spacing: 12, checkScroll: false)
        audit(app, page: "home-hot", prefix: "home_hot_", columns: 6, spacing: 12, checkScroll: false)
        audit(app, page: "home-top", prefix: "home_top_", columns: 6, spacing: 12, checkScroll: false)

        // 2) 浏览（2 列）
        openTab(app, "browse")
        _ = app.descendants(matching: .any)["browse_grid"].firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        audit(app, page: "browse", prefix: "card_browse_", columns: 2, spacing: 12, checkScroll: true)

        // 3) 女优（3 列）
        openTab(app, "actors")
        _ = app.descendants(matching: .any)["card_actors_0"].firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        audit(app, page: "actors", prefix: "card_actors_", columns: 3, spacing: 12, checkScroll: true)

        // 4) 98t（2 列）
        openTab(app, "sht")
        _ = app.descendants(matching: .any)["card_sht_0"].firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        audit(app, page: "sht", prefix: "card_sht_", columns: 2, spacing: 12, checkScroll: true)

        // 5) 资讯（1 列行卡 96）
        openTab(app, "search")
        _ = tapIfExist(app.buttons["entry_articles"])
        _ = app.descendants(matching: .any)["article_card"].firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        audit(app, page: "articles", prefix: "article_card", columns: 1, spacing: 10, checkScroll: true)
        app.navigationBars.buttons.firstMatch.exists ? navBack(app) : ()

        // 6) 热评（1 列行卡）
        openTab(app, "search")
        _ = tapIfExist(app.buttons["entry_hotreviews"])
        _ = app.descendants(matching: .any)["hot_review_row"].firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        audit(app, page: "hot-reviews", prefix: "hot_review_row", columns: 1, spacing: 8, checkScroll: true)
        navBack(app)

        // 7) TOP250（1 列行卡 112）
        openTab(app, "search")
        _ = tapIfExist(app.buttons["viewall_top"])
        _ = app.descendants(matching: .any)["top250_row"].firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        audit(app, page: "top250", prefix: "top250_row", columns: 1, spacing: 10, checkScroll: true)
        navBack(app)

        // 8) 收藏（1 列行卡）
        openTab(app, "favs")
        _ = app.descendants(matching: .any)["fav_row"].firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        audit(app, page: "favs", prefix: "fav_row", columns: 1, spacing: 8, checkScroll: false)

        flushReport()
        XCTAssertTrue(report.isEmpty, "layout violations: \(report.count) → layout-report.json")
    }

    private func navBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        Thread.sleep(forTimeInterval: 0.6)
    }
}
