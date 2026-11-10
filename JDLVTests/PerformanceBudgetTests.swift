import XCTest

// R4 Phase 0 性能基线（P3/P4 接入预算断言）：
//  - 内存预算：XCTMemoryMetric 包住确定性解码负载（演示数据 JSON 解码量级）；
//  - 时钟预算：XCTClockMetric 包住同一负载，留下 before 数字。
// 启动指标（XCTApplicationLaunchMetric）必须跑在 UI runner（XCUIApplication），
// 由 JDLVUITests/ScrollPerfUITests.testLaunchColdBudget 承担；单元 target 不测启动。
final class PerformanceBudgetTests: XCTestCase {

    private func demoWorkload() {
        // 确定性负载：与首页卡片列表量级相当的字符串/数据构造 + 解码。
        // 不依赖网络、不依赖数据库；P3/P4 换成真实页面负载前后对比用同一负载。
        var payload = [Data]()
        let unit = Data("JDLV-perf-baseline-".utf8)
        for i in 0..<256 {
            var chunk = unit
            chunk.append(Data(String(i).utf8))
            payload.append(chunk)
        }
        var joined = Data()
        for chunk in payload {
            joined.append(chunk)
        }
        let decoded = String(data: joined, encoding: .utf8) ?? ""
        XCTAssertGreaterThan(decoded.count, 0)
        payload.removeAll()
        joined.removeAll()
    }

    func testMemoryBudgetBaseline() {
        measure(metrics: [XCTMemoryMetric()]) {
            demoWorkload()
        }
    }

    func testWorkloadClockBaseline() {
        measure(metrics: [XCTClockMetric()]) {
            demoWorkload()
        }
    }
}
