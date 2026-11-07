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
}
