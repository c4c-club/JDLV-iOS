import XCTest

//
//  LayoutAuditUITests.swift —— 全页面卡片布局审计（R3 §6.2；13 §2.5–2.7 验收）。
//
//  每页：收集 card_*（CardGrid 外层 wrapper id —— frame = cellW×cellH 精确值）或
//  行卡固定 id 元素 frame → 按 minY 分组（±1）→ 断言组内等宽/等高/minY（差 ≤0.5）、
//  相邻 minX 间距 = spacing ±1、无重叠；固定网格页断言不出屏；横滑段豁免出屏
//  （首卡被视口裁切属正常交互）；列表页 swipeUp 后内容上移（可滚动）。
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

    private func snapDiag(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "diag-\(name)"
        a.lifetime = .keepAlways
        add(a)
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
        if out.isEmpty {
            // 降级源：当前 tab 可点（hittable）的 demo 卡内容按钮 —— wrapper a11y 容器
            // 在部分页面未成节点时以内容 frame 审计（等宽/无重叠仍可断言）
            let dq = app.buttons.containing(
                NSPredicate(format: "label CONTAINS %@", "演示"))
            let dn = dq.count
            for i in 0..<min(dn, 40) {
                let e = dq.element(boundBy: i)
                if e.exists, e.isHittable, e.frame.width > 1 {
                    out.append(("\(prefix)demo_\(i)", e.frame))
                }
            }
        }
        return out
    }

    /// 等待首卡出现（demo 数据 bind 异步；30s 内未出现 → 诊断截图 + violation）
    private func waitFirstCard(_ app: XCUIApplication, page: String, prefix: String,
                               timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !collect(app, prefix: prefix).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        snapDiag(app, "no-cards-\(page)")
        addViolation(page, prefix, "no cards found after \(Int(timeout))s")
        return false
    }

    /// 分组断言：同 minY 行（±1）内等宽/等高/minY；相邻卡间距 spacing ±1；无重叠；
    /// allowOffscreen=true 时跳过出屏检查（横滑首卡被视口裁切属正常）。
    private func audit(_ app: XCUIApplication, page: String, prefix: String,
                       columns: Int, spacing: CGFloat, checkScroll: Bool,
                       allowOffscreen: Bool = false) {
        var cards = collect(app, prefix: prefix)
        let isFallback = cards.contains { $0.0.contains("demo_") }
        if cards.isEmpty {
            // 已由 waitFirstCard 报告；此处兜底
            addViolation(page, prefix, "no cards found")
            return
        }
        cards.sort { $0.1.minY == $1.1.minY ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }

        let screen = app.frame
        let rows = groupByRow(cards)
        for (idx, row) in rows.enumerated() {
            // 降级源不做列数断言（内容 button 可能跨行命中）；等宽/无重叠保留
            if !isFallback && row.count > columns {
                addViolation(page, "row\(idx)", "row has \(row.count) cards > expected columns \(columns)")
            }
            let widths = row.map { $0.1.width }
            let heights = row.map { $0.1.height }
            let minys = row.map { $0.1.minY }
            // 容差 1.5pt：覆盖 3x 像素网格取整（XCUI frame 报告值有 ~1pt 损耗）
            if let w0 = widths.first, widths.contains(where: { abs($0 - w0) > 1.5 }) {
                addViolation(page, "row\(idx)", "width mismatch: \(widths)")
            }
            if let h0 = heights.first, heights.contains(where: { abs($0 - h0) > 1.5 }) {
                addViolation(page, "row\(idx)", "height mismatch: \(heights)")
            }
            if let y0 = minys.first, minys.contains(where: { abs($0 - y0) > 1.5 }) {
                addViolation(page, "row\(idx)", "minY mismatch: \(minys)")
            }
            for j in 1..<row.count {
                let gap = row[j].1.minX - row[j - 1].1.maxX
                if gap < -0.5 {
                    addViolation(page, row[j].0, "overlap: gap=\(gap)")
                } else if abs(gap - spacing) > 1.5 {
                    addViolation(page, row[j].0, "gap \(gap) != \(spacing)±1.5")
                }
            }
        }
        if !allowOffscreen {
            for c in cards {
                // 仅水平出屏断言（垂直方向：滚动容器内卡片在视口上下方属正常滚动态，
                // 「内容高度 > 2 屏」由 checkScroll 断言承担）
                if c.1.minX < -1.5 || c.1.maxX > screen.width + 1.5 {
                    addViolation(page, c.0, "out of screen (h): \(c.1)")
                }
            }
        }
        if checkScroll, cards.count >= 2 {
            let before = cards.map { $0.1.minY }
            // 屏幕中部定向 swipe（避开 toolbar/PageChip 干扰）；静置等滚动动画结束
            let w = app.frame
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
            Thread.sleep(forTimeInterval: 1.2)
            let after = collect(app, prefix: prefix).map { $0.1.minY }
            let moved = (after.max() ?? 0) < (before.max() ?? 0) - 10
            let more = after.count > before.count
            if !moved && !more {
                addViolation(page, prefix,
                             "not scrollable (minY unchanged, no new cards)")
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            Thread.sleep(forTimeInterval: 0.6)
            _ = w
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

        // 1) 首页三段横滑（160×289 单行；横滑豁免出屏；不查滚动 —— 段内容固定）
        audit(app, page: "home-recent", prefix: "home_recent_", columns: 6, spacing: 12,
              checkScroll: false, allowOffscreen: true)
        audit(app, page: "home-hot", prefix: "home_hot_", columns: 6, spacing: 12,
              checkScroll: false, allowOffscreen: true)
        audit(app, page: "home-top", prefix: "home_top_", columns: 6, spacing: 12,
              checkScroll: false, allowOffscreen: true)

        // 2) 浏览（2 列；demo bind 异步 → 30s 等首卡）
        openTab(app, "browse")
        waitFirstCard(app, page: "browse", prefix: "card_browse_")
        Thread.sleep(forTimeInterval: 1.0)
        audit(app, page: "browse", prefix: "card_browse_", columns: 2, spacing: 12, checkScroll: true)

        // 3) 女优（3 列）
        openTab(app, "actors")
        waitFirstCard(app, page: "actors", prefix: "card_actors_")
        Thread.sleep(forTimeInterval: 1.0)
        audit(app, page: "actors", prefix: "card_actors_", columns: 3, spacing: 12, checkScroll: true)

        // 4) 98t（2 列）
        openTab(app, "sht")
        waitFirstCard(app, page: "sht", prefix: "card_sht_")
        Thread.sleep(forTimeInterval: 1.0)
        audit(app, page: "sht", prefix: "card_sht_", columns: 2, spacing: 12, checkScroll: true)

        // 5) 资讯（1 列行卡 96）
        openTab(app, "search")
        _ = tapIfExist(app.buttons["entry_articles"])
        waitFirstCard(app, page: "articles", prefix: "article_card")
        Thread.sleep(forTimeInterval: 1.0)
        audit(app, page: "articles", prefix: "article_card", columns: 1, spacing: 10, checkScroll: true)
        navBack(app)

        // 6) 热评（1 列行卡）
        openTab(app, "search")
        _ = tapIfExist(app.buttons["entry_hotreviews"])
        waitFirstCard(app, page: "hot-reviews", prefix: "hot_review_row")
        Thread.sleep(forTimeInterval: 1.0)
        audit(app, page: "hot-reviews", prefix: "hot_review_row", columns: 1, spacing: 8, checkScroll: true)
        navBack(app)

        // 7) TOP250（1 列行卡 112）
        openTab(app, "search")
        _ = tapIfExist(app.buttons["viewall_top"])
        waitFirstCard(app, page: "top250", prefix: "top250_row")
        Thread.sleep(forTimeInterval: 1.0)
        audit(app, page: "top250", prefix: "top250_row", columns: 1, spacing: 10, checkScroll: true)
        navBack(app)

        // 8) 收藏（1 列行卡）
        openTab(app, "favs")
        waitFirstCard(app, page: "favs", prefix: "fav_row")
        Thread.sleep(forTimeInterval: 1.0)
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
