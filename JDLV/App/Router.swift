import Foundation
import SwiftUI
import JDLVCore

//
//  Router.swift —— 路由骨架（07 A3 路由表 / A4 导航不变量）。
//
//  - Route 枚举对齐 Android 路由表：movie/{mid}、actor/{aid}、sht/{tid}、articles、
//    article/{aid}、hotreviews、top250、lookup?payload={payload}。
//  - 每 Tab 独立 NavigationStack(path)：6 个 path 各自保活，Tab 切换保留状态
//    （对齐 Android popUpTo saveState/restoreState + 单实例）。
//  - 反查压栈：lookup 携带 payload（LookupCodec.encode(LookupSpec) 的 Base64 URL-safe
//    无填充串），每次点击压一层、返回逐层回详情；绝不 popBackStack 弹掉详情页。
//  - 二级页 .toolbar(.hidden, for: .tabBar)（底栏仅顶层 route 显示）。
//  - startDestination = "search"。
//

/// 二级路由（每条都是二级页 → 一律隐藏 TabBar）。
enum Route: Hashable {
    /// movie/{mid}
    case movie(String)
    /// actor/{aid}
    case actor(String)
    /// sht/{tid}
    case shtThread(String)
    /// 首页二级页（资讯列表）
    case articles
    /// article/{aid}
    case article(String)
    /// 首页二级页（热评）
    case hotreviews
    /// TOP250 完整页
    case top250
    /// 反查压栈：payload = LookupCodec.encode(spec)；解码失败兜底空态
    case lookup(String)
}

/// 每 Tab 独立导航栈（Tab 切换保留状态；反查/详情压栈只动当前 Tab 的 path）。
@MainActor
final class Router: ObservableObject {
    /// 6 个顶层 route 固定顺序（A3 TOP_DESTS）
    static let tabs = ["search", "browse", "actors", "sht", "favs", "settings"]
    /// startDestination = "search"（07 A3）
    static let startTab = "search"

    /// 当前选中 Tab
    @Published var tab: String = Router.startTab

    // 每 Tab 独立 path（状态保存/恢复）
    @Published var searchPath: [Route] = []
    @Published var browsePath: [Route] = []
    @Published var actorsPath: [Route] = []
    @Published var shtPath: [Route] = []
    @Published var favsPath: [Route] = []
    @Published var settingsPath: [Route] = []

    // MARK: path 读写

    func path(for tabName: String) -> [Route] {
        switch tabName {
        case "browse": return browsePath
        case "actors": return actorsPath
        case "sht": return shtPath
        case "favs": return favsPath
        case "settings": return settingsPath
        default: return searchPath
        }
    }

    /// 当前 Tab 压栈（nav("movie/{id}") 对位；LocalNav/LocalLookup 都汇到这里）
    func push(_ route: Route) {
        push(route, to: tab)
    }

    func push(_ route: Route, to tabName: String) {
        switch tabName {
        case "browse": browsePath.append(route)
        case "actors": actorsPath.append(route)
        case "sht": shtPath.append(route)
        case "favs": favsPath.append(route)
        case "settings": settingsPath.append(route)
        default: searchPath.append(route)
        }
    }

    /// 当前 Tab 回退一层
    func pop() {
        pop(tab)
    }

    func pop(_ tabName: String) {
        switch tabName {
        case "browse": if !browsePath.isEmpty { browsePath.removeLast() }
        case "actors": if !actorsPath.isEmpty { actorsPath.removeLast() }
        case "sht": if !shtPath.isEmpty { shtPath.removeLast() }
        case "favs": if !favsPath.isEmpty { favsPath.removeLast() }
        case "settings": if !settingsPath.isEmpty { settingsPath.removeLast() }
        default: if !searchPath.isEmpty { searchPath.removeLast() }
        }
    }
}
