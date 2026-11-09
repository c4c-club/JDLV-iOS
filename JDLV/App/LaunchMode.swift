import Foundation

//
//  LaunchMode.swift —— 启动模式唯一判定（A8/R8）。
//
//  严格 `-JDLV_DEMO 1` = 演示；任意其它形态（缺失 / `-JDLV_DEMO 0` / 缺后续参数）= 生产。
//  修复旧歧义：AppGate 用 contains("-JDLV_DEMO") 跳过首启门禁，而 DemoDataSource 要求
//  严格 "1" —— `-JDLV_DEMO 0` 会「跳过门禁却走生产 Q 且无演示数据」。两者现共用本判定。
//
//  Release 恒生产：AppGate.isDemoMode 内再做 #if DEBUG 门（演示数据源整体仅 DEBUG）。
//

enum LaunchMode: Equatable {
    case production
    case demo

    static func parse(_ args: [String]) -> LaunchMode {
        guard let i = args.firstIndex(of: "-JDLV_DEMO"),
              i + 1 < args.count, args[i + 1] == "1" else {
            return .production
        }
        return .demo
    }

    static var current: LaunchMode {
        parse(ProcessInfo.processInfo.arguments)
    }

    /// UI 测试专用：启动后自动以该词执行搜索（DEBUG + demo；绕开 CI 模拟器
    /// typeText 合成事件丢字符的已知问题 —— R3 B2 blocker 的修复）。
    /// 格式：-JDLV_TEST_SEARCH <query>；Release / 生产模式恒 nil。
    static var testSearchQuery: String? {
        #if DEBUG
        guard current == .demo else { return nil }
        guard let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-JDLV_TEST_SEARCH"),
              i + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        let q = ProcessInfo.processInfo.arguments[i + 1]
        return q.isEmpty ? nil : q
        #else
        return nil
        #endif
    }
}
