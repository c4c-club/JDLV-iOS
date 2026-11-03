import Foundation

//
//  AppCopy.swift —— 共享组件逐字文案集中点（含全角/半角标点差异，照抄对应上下文）。
//
//  半角/全角对照（07 §C8.4 / 08 附表）：
//  - `(恢复后下拉刷新)`、`(需抓取端上传)`、`(每页 40 条)` 半角括号；
//  - `（最多约 N 页）`、`（服务器与手机需在同一局域网…）` 全角括号；
//  - `刷新失败：`、`远程库不可达：`、`当前：` 全角冒号；`番号:{v}`、`导出失败:` 半角；
//  - `已加载 {l} 条 · 总数未知 (每页 {per} 条), 可直接输入页码` 中为半角逗号+空格；
//  - `跳页过深（最多约 {p} 页），请用滚动加载` 全角括号+全角逗号。
//
enum AppCopy {
    private init() {}

    // MARK: 下拉刷新指示（ListScaffold 四态文案，07 B10 / 08 A.1）

    static let refreshTextRefreshing = "正在刷新…"
    static let refreshTextPull = "下拉可以刷新"
    static let refreshTextRelease = "松开立即刷新"

    // MARK: 刷新结果 Toast（RefreshResult 消费，07 C0 / 08 A.1）

    static func refreshDoneToast(_ n: Int) -> String { "✓ 刷新完成 · 共 \(n) 条" }
    /// 全角冒号；msg 取前 40 字
    static func refreshFailToast(_ msg: String) -> String { "刷新失败：\(String(msg.prefix(40)))" }

    // MARK: 顶部横幅（07 A5）

    /// offlineLabel 按库拼接（javdb · 98t）；半角括号、全角冒号
    static func offlineBanner(_ label: String) -> String {
        "⚠ 远程库不可达：\(label) — 正在显示缓存数据 (恢复后下拉刷新)"
    }
    /// 恢复横幅：6 秒自消，不触发列表自动重拉
    static let restoredBanner = "✓ 网络已恢复 — 下拉刷新查看最新数据"

    // MARK: 状态框（B5/B6 / 08 A.6）

    static let errorIcon = "⚠️"
    static let emptyIcon = "🗂"
    static let retryButton = "重试"

    // MARK: AppSwitchRow 徽标（B7，两态文案逐字）

    static let switchOnBadge = "已开启"
    static let switchOffBadge = "已关闭"

    // MARK: LoadMoreFooter（B19 / 08 A.5）

    static let loadMore = "加载更多"
    static let noMore = "没有更多了"
    static func loadedLine(loaded: Int, total: Int64, approx: Bool) -> String {
        if total > 0 {
            return approx ? "已加载 \(loaded) · 约 \(total) 条" : "已加载 \(loaded) / \(total)"
        }
        return "已加载 \(loaded) 条"
    }

    // MARK: PageChip / 跳页对话框（B18 / 08 A.5 / 10 §0.4）

    /// total>0 → "{loaded} / {total}"；否则 "{loaded} / ?"（半角斜杠两侧空格）
    static func pageChipLabel(loaded: Int, total: Int64) -> String {
        total > 0 ? "\(loaded) / \(total)" : "\(loaded) / ?"
    }
    static let pageJumpTitle = "跳转页码"
    static let pageJumpPlaceholder = "输入页码"
    static let pageJumpGo = "跳转"
    static let pageJumpCancel = "取消"
    /// total 已知：全角「·」+ 半角括号；pages = ceil(total/per)
    static func pageJumpBodyKnown(loaded: Int, total: Int64, per: Int) -> String {
        let pages = Int(ceil(Double(total) / Double(max(per, 1))))
        return "已加载 \(loaded) / \(total) · 共 \(pages) 页 (每页 \(per) 条)"
    }
    /// total 未知（按 loaded 估页）：半角逗号+空格
    static func pageJumpBodyUnknown(loaded: Int, per: Int) -> String {
        "已加载 \(loaded) 条 · 总数未知 (每页 \(per) 条), 可直接输入页码"
    }
    /// 跳页钳制 Toast（PaginationGuard 触发时；全角括号+全角逗号）
    static func tooDeepToast(maxPage: Int) -> String {
        "跳页过深（最多约 \(maxPage) 页），请用滚动加载"
    }

    // MARK: 回顶 FAB（B17）

    static let scrollTopIcon = "↑"

    // MARK: PosterImage 三态（B12）

    static let posterFailedRetry = "加载失败 · 点击重试"

    // MARK: MovieCard / ShtCard 元信息（B11/B13，顺序与条件逐字）

    /// release_date（非空）、想看 {n}（>0）、磁 {n}（>0）、★已收藏（fav），" · " 连接
    static func movieMetaParts(releaseDate: String, wantWatch: Int64, magnets: Int64, fav: Bool) -> [String] {
        var parts: [String] = []
        if !releaseDate.isEmpty { parts.append(releaseDate) }
        if wantWatch > 0 { parts.append("想看 \(wantWatch)") }
        if magnets > 0 { parts.append("磁 \(magnets)") }
        if fav { parts.append("★已收藏") }
        return parts
    }

    /// post_date、board_name、磁 {n}（>0）、★已收藏（fav），" · " 连接
    static func shtMetaParts(postDate: String, boardName: String, magnetCount: Int64, fav: Bool) -> [String] {
        var parts: [String] = []
        if !postDate.isEmpty { parts.append(postDate) }
        if !boardName.isEmpty { parts.append(boardName) }
        if magnetCount > 0 { parts.append("磁 \(magnetCount)") }
        if fav { parts.append("★已收藏") }
        return parts
    }

    static func joinMeta(_ parts: [String]) -> String {
        parts.joined(separator: " · ")
    }

    // MARK: ActorCard（B15）

    /// "{videos_count} 部" + avg>0 时 " · ★{%.2f}"
    static func actorMetaLine(videosCount: Int64, avgScoreAll: Double) -> String {
        var s = "\(videosCount) 部"
        if avgScoreAll > 0 {
            s += " · ★" + String(format: "%.2f", avgScoreAll)
        }
        return s
    }

    // MARK: 视图切换（B9）

    static let viewSmall = "小图"
    static let viewLarge = "大图"
    static let viewList = "列表"

    // MARK: 反查（10 §6.2）

    static let lookupInvalid = "反查参数无效"
    static let lookupInvalidHint = "按返回键重试"
    static let lookupDefaultLabel = "反查"

    // MARK: 占位页（P8）

    static let p9Placeholder = "该页 P9 实现"
}
