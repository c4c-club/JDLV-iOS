import Foundation
import os

/// R4 P3：启动/首屏打点（os_signpost；Instruments pointsOfInterest 轨道可见）。
/// launch 语义：JDLVApp.init = t0；AppRoot 首次出现 = begin；HomeView 首屏数据
/// （vm.items 首次非空）= end（同时落 firstCardMs 数字，供 UI 测试/CI 证据读取）。
/// beginLaunchOnce/endLaunchOnce 幂等（Once 语义），重复触发无副作用。
/// 日志/打点不含任何敏感信息（只有固定区间名与毫秒数）。
enum PerfSignposts {
    static let launch = OSLog(subsystem: "com.jdlv.ios", category: .pointsOfInterest)

    private static var launchOpen = false
    /// R7 P2：进程冷启动 t0（JDLVApp.init 最早时机）
    private static var t0: CFAbsoluteTime = 0
    /// 首屏数据到位耗时（毫秒；-1 = 未就绪；HomeView AX probe 跨进程读取）
    private(set) static var firstCardMs: Int64 = -1

    static func markLaunchT0() {
        t0 = CFAbsoluteTimeGetCurrent()
    }

    static func beginLaunchOnce() {
        guard !launchOpen else { return }
        launchOpen = true
        os_signpost(.begin, log: launch, name: "launch")
    }

    static func endLaunchOnce() {
        guard launchOpen else { return }
        launchOpen = false
        os_signpost(.end, log: launch, name: "launch")
        let ms = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        firstCardMs = ms
        print("[Perf] firstCard=\(ms)ms")
    }

    /// 通用区间打点（调用方自行配对 begin/end；同 name 嵌套自担）
    static func begin(_ name: StaticString) { os_signpost(.begin, log: launch, name: name) }
    static func end(_ name: StaticString) { os_signpost(.end, log: launch, name: name) }

    /// R7 P2：数字打点（"[Perf] key=Nms"；只有毫秒数，无敏感值；Release 保留）
    static func mark(_ key: StaticString, _ ms: Int64) {
        print("[Perf] \(key)=\(ms)ms")
    }

    // MARK: 主线程卡顿 watchdog（启动后 N 秒；Release 保留，仅计数）

    private static var hitchTimer: Timer?
    private static var hitchCount = 0
    private static var lastTick: Date?
    private static var hitchDeadline: Date?

    /// 50ms 心跳 tick，相邻 tick 实际间隔 >150ms 即记一次 >100ms 停顿；
    /// 到期输出 "[Perf] hitchCount=N"（.common mode 保证滚动中仍计时）。
    static func startHitchWatch(seconds: TimeInterval) {
        guard hitchTimer == nil else { return }
        hitchCount = 0
        lastTick = Date()
        hitchDeadline = lastTick?.addingTimeInterval(seconds)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            let now = Date()
            if let dl = hitchDeadline, now >= dl {
                t.invalidate()
                hitchTimer = nil
                lastTick = nil
                hitchDeadline = nil
                print("[Perf] hitchCount=\(hitchCount) in \(Int(seconds))s")
                return
            }
            if let last = lastTick, now.timeIntervalSince(last) > 0.15 {
                hitchCount += 1
            }
            lastTick = now
        }
        hitchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
