import os

/// R4 P3：启动/首屏打点（os_signpost；Instruments pointsOfInterest 轨道可见）。
/// launch 语义：AppRoot 首次出现 = begin；HomeView 首屏数据（vm.items 首次非空）= end。
/// beginLaunchOnce/endLaunchOnce 幂等（Once 语义），重复触发无副作用。
/// 日志/打点不含任何敏感信息（只有固定区间名与 visitedTabs 路由名）。
enum PerfSignposts {
    static let launch = OSLog(subsystem: "com.jdlv.ios", category: .pointsOfInterest)

    private static var launchOpen = false

    static func beginLaunchOnce() {
        guard !launchOpen else { return }
        launchOpen = true
        os_signpost(.begin, log: launch, name: "launch")
    }

    static func endLaunchOnce() {
        guard launchOpen else { return }
        launchOpen = false
        os_signpost(.end, log: launch, name: "launch")
    }

    /// 通用区间打点（调用方自行配对 begin/end；同 name 嵌套自担）
    static func begin(_ name: StaticString) { os_signpost(.begin, log: launch, name: name) }
    static func end(_ name: StaticString) { os_signpost(.end, log: launch, name: name) }
}
