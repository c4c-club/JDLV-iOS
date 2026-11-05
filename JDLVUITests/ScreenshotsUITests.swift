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
}
