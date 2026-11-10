import Foundation
import SwiftUI
import JDLVCore

//
//  FavsVM.swift —— 收藏页 VM（10 §7 + 14_vm_tests A.5）。
//
//  职责：本地收藏三 tab（movie/sht/actor）。无分页、无网络、无 QCache。
//  状态（A.5 FavsUi 逐字段）：loading/movie/sht/actor: [Row] + 辅助 count(tab)/rows(tab)。
//
//  契约：
//  - reload：store.favList(kind)（本地 SQLite 也是磁盘 IO，后台执行）→ 每行 map
//    {kind, id, title, ts}；bind 即 reload；本页不随 dataEpoch 自动刷新（§7.3）。
//  - 生产：LocalStore（BrowseMarks 单例宿主 jdlv_local.db，ts REAL 秒）；
//    demo：DemoStore.favList（favorites 表 ts 毫秒）→ tsToMillis 双口径归一（>1e12 视毫秒）。
//  - ts<=0（异常数据）显示「时间未知」（不显示 1970-01-01，A-9）。
//  - 导出收藏：文本组装（逐字格式）→ 系统分享面板。
//

// MARK: - 收藏存储协议（生产 LocalStore / demo DemoStore 同一协议注入）

protocol FavsStore {
    /// 对齐 LocalStore.favList：行键 kind/id/title/ts；ts DESC（新→旧）
    /// R4 P6/P9：async throws —— SQLite 在 LocalStoreActor 后台执行；错误不吞（与空收藏区分）
    func favList(kind: String) async throws -> [Row]
    /// 取消收藏（R3 问题 11 §4.12 swipeActions；demo no-op）
    func favRemove(kind: String, id: String, title: String) async throws
}

extension FavsStore {
    func favRemove(kind: String, id: String, title: String) async throws {}
}

/// 本地存储不可用（打开失败/目录不可写；P9 显式错误态）
struct StoreUnavailable: Error, CustomStringConvertible {
    var description: String { "本地存储不可用" }
}

/// 生产：Core LocalStore（jdlv_local.db；LocalStoreActor 串行后台执行）
/// R4 P6：不在 init 打开 SQLite —— 首次使用经 BrowseMarks.open() 后台打开；
/// 打开失败 → 抛 StoreUnavailable（P9：绝不静默当空收藏）。
final class LocalFavsStore: FavsStore {
    private var impl: LocalStoreActor?

    private func openIfNeeded() async {
        if impl == nil { impl = await BrowseMarks.open() }
    }

    func favList(kind: String) async throws -> [Row] {
        await openIfNeeded()
        guard let impl else { throw StoreUnavailable() }
        return try await impl.favList(kind: kind)
    }

    func favRemove(kind: String, id: String, title: String) async throws {
        await openIfNeeded()
        guard let impl else { throw StoreUnavailable() }
        // 已收藏态 toggle → 取消收藏
        _ = try await impl.favToggle(kind: kind, itemId: id, title: title)
    }
}

#if DEBUG

/// demo：DemoStore.favorites（预置 影片 3 / 帖子 2 / 女优 2）
struct DemoFavsStore: FavsStore {
    func favList(kind: String) async -> [Row] {
        DemoStore.shared.favList(kind: kind)
    }
}

#endif

// MARK: - 逐字文案（10 §7）

enum FavsCopy {

    /// 三 tab（文案带数量；半角括号）
    static let tabs: [(label: String, kind: String)] = [
        ("影片", "movie"), ("帖子", "sht"), ("女优", "actor"),
    ]
    static func tabLabel(_ label: String, _ n: Int) -> String { "\(label) (\(n))" }

    /// 行卡标题空 → (无标题)
    static let noTitle = "(无标题)"
    /// ts<=0（异常数据）
    static let unknownTime = "时间未知"
    /// 空态（破折号 " — " + ☆ 逐字）
    static let emptyText = "暂无收藏 — 在详情页点 ☆ 收藏"
    /// 顶部导出按钮
    static let exportButton = "导出收藏"

    // 导出文本（逐字格式）
    /// 首行：JDLV 收藏导出 + 空格 + 当前时间
    static func exportHeader(_ now: String) -> String { "JDLV 收藏导出 \(now)" }
    /// 段头（即使为 0 也输出）：\n\n== 影片 (n) ==
    static func exportSection(_ label: String, _ n: Int) -> String {
        "\n\n== \(label) (\(n)) ==\n"
    }
    /// 每条：- {title}；有时间尾缀 "  [{yyyy-MM-dd HH:mm}]"（两个空格），无时间空尾缀
    static func exportLine(_ title: String, _ timeSuffix: String) -> String {
        "- \(title.isEmpty ? noTitle : title)\(timeSuffix)"
    }
    /// 时间尾缀（两个空格 + [时间]）
    static func exportTimeSuffix(_ time: String?) -> String {
        guard let time, !time.isEmpty else { return "\n" }
        return "  [\(time)]\n"
    }
    /// 分享 subject
    static let exportSubject = "JDLV 收藏导出"

    /// R4 P9：本地存储读取失败文案（与空收藏区分）
    static let loadFailed = "收藏读取失败：本地存储不可用（下拉重试）"
}

// MARK: - 时间格式化（yyyy-MM-dd HH:mm 本地时区；ts 双口径归一）

enum FavsFmt {
    /// R4 P10：formatter 复用（每行 new 在千行导出时 CPU 抖动；DateFormatter iOS7+ 线程安全）
    private static let df: DateFormatter = {
        let d = DateFormatter()
        d.dateFormat = "yyyy-MM-dd HH:mm"
        d.locale = Locale(identifier: "en_US_POSIX")
        return d
    }()

    /// yyyy-MM-dd HH:mm（本地时区）；nil/空 → nil
    static func fullDateTime(fromMs ms: Int64?) -> String? {
        guard let ms, ms > 0 else { return nil }
        return df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// ts 双口径归一为毫秒：>1e12 视为毫秒，否则秒（秒值域 <1e12 到 33658 年）；<=0 → nil
    static func tsToMillis(_ ts: Int64) -> Int64? {
        guard ts > 0 else { return nil }
        return ts > 1_000_000_000_000 ? ts : ts * 1000
    }
}

// MARK: - FavsVM（A.5）

@MainActor
final class FavsVM: ObservableObject {

    let store: FavsStore
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    init(store: FavsStore? = nil) {
        #if DEBUG
        self.store = store
            ?? (DemoDataSource.enabled()
                ? DemoFavsStore()
                : LocalFavsStore())
        #else
        self.store = store ?? LocalFavsStore()
        #endif
    }

    static func makeDefault() -> FavsVM { FavsVM() }

    // MARK: 状态（A.5 逐字段）

    @Published var loading = false
    /// R4 P9：读取失败显式态（nil = 正常；非 nil = 本地存储错误，与空收藏区分）
    @Published var error: String? = nil
    /// 三分类（ts DESC，最新在前）
    @Published var movie: [Row] = []
    @Published var sht: [Row] = []
    @Published var actor: [Row] = []

    /// 辅助：count(tab)（tab = movie/sht/actor）
    func count(_ tab: String) -> Int { rows(tab).count }

    /// 辅助：rows(tab)
    func rows(_ tab: String) -> [Row] {
        switch tab {
        case "movie": return movie
        case "sht": return sht
        case "actor": return actor
        default: return []
        }
    }

    // MARK: reload（bind 即 reload；本地数据不随 dataEpoch 自动刷新）

    func reload() async {
        loading = true
        defer { loading = false }
        do {
            // Android A.5：三类按 movie → sht → actor 顺序拉取（seen 顺序确定）
            movie = try await store.favList(kind: "movie")
            sht = try await store.favList(kind: "sht")
            actor = try await store.favList(kind: "actor")
            self.error = nil
        } catch {
            // P9：失败保留上次数据并显式报错（绝不静默显示为空收藏；self 消歧 catch 隐式绑定）
            self.error = FavsCopy.loadFailed
        }
    }

    // MARK: remove（R3 §4.12 swipeActions 删除 → 取消收藏 + reload）

    func remove(_ r: Row) async {
        do {
            try await store.favRemove(kind: r.s("kind"), id: r.s("id"), title: r.s("title"))
        } catch {
            // P9：删除失败显式呈现（reload 会反映真实存储状态）
            self.error = FavsCopy.loadFailed
        }
        await reload()
    }

    // MARK: 行卡展示值（10 §7.2）

    /// 标题：title，空则 (无标题)
    static func rowTitle(_ r: Row) -> String {
        let t = r.s("title")
        return t.isEmpty ? FavsCopy.noTitle : t
    }

    /// 时间：yyyy-MM-dd HH:mm（本地时区）；ts<=0（异常数据）→ nil（显示「时间未知」）
    static func rowTime(_ r: Row) -> String? {
        FavsFmt.fullDateTime(fromMs: FavsFmt.tsToMillis(r.i("ts")))
    }

    // MARK: 导出收藏（10 §7.4：文本组装逐字格式 → 系统分享面板）

    /// 导出文本：首行 JDLV 收藏导出 + 当前时间；三类段（影片→帖子→女优，为 0 也输出段头）；
    /// 每条 - {title} + 时间尾缀（两个空格 + [时间]）或 \n
    static func exportText(movie: [Row], sht: [Row], actor: [Row], nowMs: Int64) -> String {
        var out = FavsCopy.exportHeader(
            FavsFmt.fullDateTime(fromMs: nowMs) ?? "")
        for (label, rows) in [("影片", movie), ("帖子", sht), ("女优", actor)] {
            out += FavsCopy.exportSection(label, rows.count)
            for r in rows {
                let time = rowTime(r)
                out += FavsCopy.exportLine(r.s("title"), FavsCopy.exportTimeSuffix(time))
            }
        }
        return out
    }

    /// 当前导出文本（页面分享入口）
    func exportText() -> String {
        Self.exportText(movie: movie, sht: sht, actor: actor, nowMs: nowMs())
    }
}
