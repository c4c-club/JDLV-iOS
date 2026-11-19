import XCTest

//
//  ActorsAvatarUITests.swift —— R7-P5（任务 06 步骤 5）女优页头像成功率骨架验证。
//
//  demo 环境（TestImages 合成图）下头像恒为 ok —— 本用例验证 AX 通道
//  （actoravatar_N 的 accessibilityValue = nocover/loading/ok/failed）与
//  「前 12 个头像 failed 占位 ≤ 2」断言链路；真实头像成功率 >= 90% 需真机
//  无代理 + 远程库（任务 06 验收命令第 2 行, BLOCKED(ENV) 记录于 p5 证据）。
//
final class ActorsAvatarUITests: XCTestCase {

    @MainActor
    func testActorsPageAvatarFailureRateBounded() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()

        let actorsTab = app.buttons["tab_actors"].firstMatch
        XCTAssertTrue(actorsTab.waitForExistence(timeout: 20), "tab bar not found")
        if actorsTab.isHittable {
            actorsTab.tap()
        } else {
            actorsTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        // 前 12 个头像节点进入 AX 树（滚动加载可能慢, 逐个等首屏即可）
        let first = app.descendants(matching: .any)["actoravatar_0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "avatar AX channel missing")

        Thread.sleep(forTimeInterval: 5)   // 任务口径: 等待 5s 后统计

        var failed = 0
        var seen = 0
        for i in 0..<12 {
            let node = app.descendants(matching: .any)["actoravatar_\(i)"].firstMatch
            guard node.exists else { continue }
            seen += 1
            if (node.value as? String) == "failed" { failed += 1 }
        }
        XCTAssertGreaterThanOrEqual(seen, 10, "AX 通道应覆盖前 12 个头像中的 >= 10 个")
        XCTAssertLessThanOrEqual(failed, 2, "头像 failed 占位应 <= 2/12（demo 合成图恒 ok）")
    }
}
