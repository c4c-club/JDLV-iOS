import XCTest

// R6 SEG-04：收藏列表下方黑框回归 —— List 内零高度锚点行已移除（id 挂第一行真实收藏）；
// 最后一行卡片底边以下的空白区必须 ≈ theme.bg0（暗色 0x0F1218 = RGB 15,18,24），不得纯黑。
final class FavsBlackBandUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        // A9/R8：独立 defaults suite + 独立 Keychain service（防跨用例持久污染）
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "favsband_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    /// 采样点 RGB（截图字节序 RGBA/BGRA 均可能 —— 判定同时接受两种通道顺序）
    private func sampleRGB(_ app: XCUIApplication, _ point: CGPoint) -> (r: Int, g: Int, b: Int)? {
        guard let cg = app.screenshot().image.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let scale = CGFloat(cg.width) / app.frame.width
        let x = min(cg.width - 1, max(0, Int(point.x * scale)))
        let y = min(cg.height - 1, max(0, Int(point.y * scale)))
        let bpp = max(1, cg.bitsPerPixel / 8)
        let off = y * cg.bytesPerRow + x * bpp
        return (Int(bytes[off]), Int(bytes[off + 1]), Int(bytes[off + 2]))
    }

    private func nearBg0(_ rgb: (r: Int, g: Int, b: Int)) -> Bool {
        let target: (Int, Int, Int) = (15, 18, 24)   // dark bg0 0x0F1218
        let a = abs(rgb.r - target.0) <= 10 && abs(rgb.g - target.1) <= 10 && abs(rgb.b - target.2) <= 10
        let b = abs(rgb.b - target.0) <= 10 && abs(rgb.g - target.1) <= 10 && abs(rgb.r - target.2) <= 10
        return a || b   // BGRA 字节序时 r/b 互换
    }

    func testNoBlackBandBelowFavsList() throws {
        let app = launchDemo()
        let favsTab = app.buttons["tab_favs"]
        XCTAssertTrue(favsTab.waitForExistence(timeout: 15), "TabBar 未出现")
        favsTab.tap()

        let rows = app.descendants(matching: .any).matching(identifier: "fav_row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "收藏列表未出现")
        // demo 种子：影片 3 / 帖子 2 / 女优 2 —— 默认 tab（影片）= 3 行；
        // 零高度锚点行删除后 fav_row 数量必须等于真实收藏数
        XCTAssertEqual(rows.count, 3, "fav_row 行数应等于真实收藏数 3（锚点行不得再占一行）")

        // 最后一行卡片底边下方采样：≈bg0，不得纯黑（修复前 = 约 44pt 黑色横条）
        var maxY: CGFloat = 0
        for i in 0..<rows.count {
            maxY = max(maxY, rows.element(boundBy: i).frame.maxY)
        }
        let screenW = app.frame.width
        let samples = [CGPoint(x: screenW / 2, y: maxY + 12),
                       CGPoint(x: screenW - 20, y: maxY + 30)]
        for p in samples {
            guard let rgb = sampleRGB(app, p) else {
                XCTFail("像素采样失败 @ \(p)")
                continue
            }
            XCTAssertFalse(rgb.r < 8 && rgb.g < 8 && rgb.b < 8,
                           "列表下方出现纯黑横条 @ \(p): rgb=\(rgb)")
            XCTAssertTrue(nearBg0(rgb), "列表下方空白应≈bg0(15,18,24) @ \(p): rgb=\(rgb)")
        }

        // 回顶 FAB（非空常显）仍可用：点击后第一行仍在
        let fab = app.buttons["scroll_top"]
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "回顶 FAB 不存在")
        fab.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "回顶后第一行丢失")
    }
}
