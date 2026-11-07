import Foundation

// ShtSearch —— 98t 搜索/列表重排（移植自 Android JDLV-Mobile）。
//
// Android 源文件: app/src/main/java/com/jdlv/mobile/core/search/ShtSearch.kt（212 行, S2 2026-10-30）
// 提取对照: docs/_extract/03_search_math.md §2（全分支 + SQL 逐字）/ §12（外部依赖签名）/ §13（口径速查）,
//           docs/_extract/02_q_db.md §0（JRow 助手语义）、§B.24/B.26（tt/cols 由 Q 传入）。SQL / 文案 / 常量逐字。
//
//  - 纯数字 3~12 位 = tid 直达 (PK) —— 保留
//  - 关键词 ≥2 字 → MATCH(title) AGAINST (ftx_sht_threads ngram, 105ms); 空格 = AND
//  - 单字 → "最近 5000 帖派生表内 LIKE" (UI 标注范围)
//  - 列表骨架: 无索引列筛选 (board_name/type/cat_name) 时, 先用派生表
//    (tid DESC LIMIT 20000, 走 PK) 截断, 再在小集合上过滤 —— 分类浏览从全表扫
//    2.8s → ~300ms; 语义上 = "最近 2 万帖内筛选" (默认列表即按时间倒序, 覆盖
//    正常浏览深度; 连续 keyset 翻页不受影响, 超出 2 万帖后自然结束)。
//  - COUNT 不是同步前置: [count] 由 VM 异步调用 (FTS COUNT 105ms; 派生表内 COUNT ~150ms)
//
// 外部依赖契约（引用其他文件/后续阶段提供的符号, 本文件不定义实现）:
//  - Db.query / Db.scalar / Db.tableOf —— Data/Db.swift（async / async throws）
//  - IdxDb 检索路复用 JdbSearch.idx 注入（同一个 IdxDb 实例, 见 IdxSearchable 协议;
//    本文件不 import/store 任何具体 IdxDb）; nil → 空结果（调用方落远程）。
//  - ShadowDb（P5 影子库）→ ShtShadowLike 注入 ShtSearch.shadow; nil → 跳过影子路。
//  - 语义模式（Q.shtBrowse mode=semantic）不在本文件 —— Android ShtSearch.list 的
//    mode 形参本身未被使用（精确/语义由 Q 层处理）, 本移植保留参数占位。
//
// 与 Data/Q.swift 末尾"搜索委托"块约定的委托签名一致（Kotlin 标签逐参对应）:
//   ShtSearch.list(tt:cols:main:cat:type:q:hasMagnet:page:per:anchor:sort:mode:)
//       async throws -> ShtSearch.Page
//   ShtSearch.count(tt:main:cat:type:q:hasMagnet:sort:) async -> Int64（内部 catch → -1）
//   ShtSearch.isTid(q:) / words(q:) / orderColOf(sort:)（同步）; fetchCovers(tids:)（async throws）

/// 影子库帖子直达注入协议 —— 对齐 Android core/cache/ShadowDb.threadById(tid): JRow?（§12）。
/// ShadowDb 在 P5 落地; 之前注入 nil, searchLocal 的 tid 直达只查 IdxDb 路。
public protocol ShtShadowLike {
    /// 影子库单帖直达（全字段行; 未命中 nil）
    func threadById(tid: String) throws -> Row?
}

public enum ShtSearch {

    // MARK: - 常量（§2.2 逐项）

    /// 单字关键词派生窗口
    private static let KEYWORD_DERIVED = 5000

    /// updated 排序派生窗口（"最近 2 万帖"）
    private static let LIST_DERIVED = 20000

    /// 影子库注入点（P5 ShadowDb; App 层启动时赋值一次; nil = 无影子库）
    public static var shadow: ShtShadowLike?

    // MARK: - 结果页

    public struct Page {
        public let items: [Row]
        public let covers: [String: String]
        public let page: Int
        public let approx: Bool
        /// 非空: 结果被派生窗口截断, UI 提示用
        public let derived: String?

        public init(items: [Row], covers: [String: String], page: Int,
                    approx: Bool, derived: String? = nil) {
            self.items = items
            self.covers = covers
            self.page = page
            self.approx = approx
            self.derived = derived
        }
    }

    // MARK: - 形态判定 / 排序列（§2.2 逐字）

    /// 3~12 位纯数字 = tid 直达
    public static func isTid(q: String) -> Bool {
        q.count >= 3 && q.count <= 12 && q.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// ★ S12-P5 (P5.1): 排序列统一 —— 列表 ORDER BY 与 keyset 条件**共用同一列名**,
    /// 锚点列必须出现在 SELECT 里 (旧版 sort=updated 时锚点取 last_checked 但
    /// SELECT 不含该列 → keyset 用错值静默错位)。返回**裸列名** (无 t. 前缀);
    /// 数据层 SQL 拼接时才加前缀。
    public static func orderColOf(sort: String) -> String {
        sort == "updated" ? "last_checked" : "post_date"
    }

    /// 列名列表 → SELECT 列 (★ S12-P5: prefixed=true 每列加 t. —— derived JOIN
    /// 分支无前缀会 1052 ambiguous, 即"结构不一致"文案的另一候选根因)
    private static func selectCols(_ cols: String, prefixed: Bool) -> String {
        if !prefixed { return cols }
        return cols
            .components(separatedBy: ",")
            .compactMap { c -> String? in
                let t = c.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : "t.\(t)"
            }
            .joined(separator: ", ")
    }

    /// 关键词 → 词列表 (空格分词 = 且, 与 web/桌面一致; 最多 8 个)
    /// 注意与 JdbSearch.words 不同: 此处在 words 内就剔除非字母数字字符
    /// （isNotBlank 先滤、剔除后 isNotEmpty 后滤, 两道都不可省）。
    public static func words(q: String) -> [String] {
        let parts = q
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }                                            // isNotBlank（trim 后非空）
            .map { $0.filter { $0.isLetter || ($0.isASCII && $0.isNumber) } }
            .filter { !$0.isEmpty }                                            // 剔除后非空
        return Array(parts.prefix(8))
    }

    // MARK: - 列表页（§2.3 逐字）

    /// 列表页 (含搜索/分类/排序/磁力筛选)。
    /// anchor 非空时走 keyset (post_date/last_checked, tid) —— 连续滚动不重扫。
    ///
    /// 计划选择 (基线实测):
    ///  - sort=date (post_date 有索引): 优化器走 idx_date 索引序扫描 + 边扫边过滤,
    ///    稠密筛选 (board/cat/magnet 命中率高) 下 LIMIT 20 在头部几百行内命中 —— 无需派生表;
    ///  - sort=updated (last_checked 无索引): ORDER BY 全表 filesort 95 万行 —— 走
    ///    "最近 2 万帖派生表" (近似, UI 标注);
    ///  - 单字关键词: FTS ngram 切不出 → 派生表内 LIKE。
    public static func list(
        tt: String, cols: String,
        main: String, cat: String, type: String, q: String,
        hasMagnet: Bool, page: Int, per: Int,
        anchor: (String, String)?, sort: String, mode: String
    ) async throws -> Page {
        var whereClause: [String] = []
        var params: [SQLValue?] = []
        if hasMagnet { whereClause.append("t.magnet_count > 0") }
        if !main.isEmpty {
            // R3 问题 9：主版 = COALESCE(board 非空串, cat_name)。真实库 board 全部
            // 非空且与 cat_name 恒等（R0 探测 648624/648632），空串/NULL 由 cat_name 兜底。
            whereClause.append("COALESCE(NULLIF(TRIM(t.board), ''), t.cat_name) = ?")
            params.append(.string(main))
        }
        if !cat.isEmpty {
            whereClause.append("t.board_name = ?")
            params.append(.string(cat))
        }
        if !type.isEmpty {
            whereClause.append("t.`type` = ?")
            params.append(.string(type))
        }

        let qs = q.trimmingCharacters(in: .whitespacesAndNewlines)
        var derivedNote: String?
        var derived = sort == "updated"       // 无索引排序 → 派生表近似
        if derived { derivedNote = "已限定最近 \(LIST_DERIVED) 帖内排序 (按更新时间)" }
        if !qs.isEmpty && !isTid(q: qs) {
            let ws = words(q: qs)
            if ws.isEmpty {
                return Page(items: [], covers: [:], page: page, approx: true)
            }
            if ws.count == 1 && ws[0].count == 1 {
                // 单字: FTS 切不出 ngram → 最近 5000 帖派生表内 LIKE
                derived = true
                derivedNote = "已限定最近 \(KEYWORD_DERIVED) 帖内匹配"
                whereClause.append("(t.title LIKE ? OR t.`type` LIKE ?)")
                params.append(.string("%\(ws[0])%"))
                params.append(.string("%\(ws[0])%"))
            } else {
                for w in ws {
                    whereClause.append("MATCH(t.title) AGAINST (? IN NATURAL LANGUAGE MODE)")
                    params.append(.string(w))
                }
            }
        } else if !qs.isEmpty {
            whereClause.append("t.tid = ?")
            params.append(.int(Int64(qs) ?? 0))
        }

        // ★ S12-P5: 排序列由 orderColOf 统一给出 (裸列名), SQL 层加 t. 前缀;
        //   keyset 条件与 ORDER BY 用同一列 (锚点列已在 SELECT 里, 见 shtListCols)
        let orderCol = "t." + orderColOf(sort: sort)
        let keyset = anchor != nil
        if let a = anchor {
            whereClause.append("(\(orderCol) < ? OR (\(orderCol) = ? AND t.tid < ?))")
            params.append(.string(a.0))
            params.append(.string(a.0))
            params.append(.string(a.1))
        }
        let offset = keyset ? 0 : (page - 1) * per

        let w = whereClause.isEmpty ? "" : " WHERE " + whereClause.joined(separator: " AND ")
        let sql = derived
            ? // ★ S12-P5: derived 分支 SELECT 全部加 t. 前缀 (JOIN 上裸列名 1052 ambiguous)
            "SELECT \(selectCols(cols, prefixed: true)) FROM (SELECT tid FROM \(tt) ORDER BY tid DESC LIMIT \(LIST_DERIVED)) k " +
                "JOIN \(tt) t ON t.tid = k.tid\(w) " +
                "ORDER BY \(orderCol) DESC, t.tid DESC LIMIT ? OFFSET ?"
            : "SELECT \(cols) FROM \(tt) t\(w) " +
                "ORDER BY \(orderCol) DESC, t.tid DESC LIMIT ? OFFSET ?"
        let rows = try await Db.query("sht", sql, params + [.int(Int64(per)), .int(Int64(offset))])
        let covers = try await fetchCovers(
            tids: rows.map { $0.s("tid") }.filter { !$0.isEmpty })
        return Page(items: rows, covers: covers, page: page, approx: true, derived: derivedNote)
    }

    // MARK: - 封面（§2.4 逐字）

    /// 封面: 一次 IN 聚合 (PK(tid,url) 前缀)
    public static func fetchCovers(tids: [String]) async throws -> [String: String] {
        if tids.isEmpty { return [:] }
        let ti = await Db.tableOf("sht", "thread_images")
        let ph = tids.map { _ in "?" }.joined(separator: ",")
        let rows = try await Db.query(
            "sht",
            "SELECT tid, MIN(url) url FROM \(ti) WHERE tid IN (\(ph)) GROUP BY tid",
            tids.map { t -> SQLValue? in .string(t) })
        var m: [String: String] = [:]
        for r in rows {
            m[r.isNull("tid") ? "" : r.s("tid")] = r.isNull("url") ? "" : r.s("url")
        }
        return m
    }

    // MARK: - 本地索引检索（§2.5 逐字）

    /// 本地索引检索 (★ S12-P0: 改走 IdxDb —— ShadowFts 已停用, 影子库不再有 FTS 行;
    /// 离线/远程失败兜底; board/board_name/type/磁力过滤在 SQL 内完成)。
    /// tid 直达: ShadowDb 优先, 未命中回退 IdxDb（★ S13-P5）, 再未命中空列表。
    public static func searchLocal(
        q: String, page: Int, per: Int,
        main: String = "", cat: String = "", type: String = "", hasMagnet: Bool = false
    ) async throws -> [Row] {
        let offset = (page - 1) * per
        let qs = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let idxDb = JdbSearch.idx
        var items: [Row]
        if !qs.isEmpty && isTid(q: qs) {
            if let sh = shadow, let hit = try sh.threadById(tid: qs) {
                items = [hit]
            } else if let ix = idxDb, let hit = try ix.threadById(tid: qs) {
                items = [hit]
            } else {
                items = []
            }
        } else if !qs.isEmpty {
            guard let ix = idxDb else { return [] }   // 未注入 = 无本地索引（调用方落远程）
            items = try ix.searchThreads(
                q: qs, board: main, boardName: cat, type: type,
                hasMagnet: hasMagnet, limit: per, offset: offset)
        } else {
            guard let ix = idxDb else { return [] }
            items = try ix.threadsBy(sort: "post_date", asc: false, limit: per, offset: offset)
        }
        // tid 直达分支仍是影子全字段行 → 内存补过滤 (其余分支 SQL 已过滤)
        var out = items
        if !qs.isEmpty && isTid(q: qs) {
            if hasMagnet {
                // 字符串字典序比较（Android: (v ?: "0") > "0"; 不要顺手改成整数比较）
                out = out.filter { r in
                    (r.isNull("magnet_count") ? "0" : r.s("magnet_count")) > "0"
                }
            }
            if !main.isEmpty {
                // 内存版无 IS NULL 限定, 与 SQL 分支不完全等价 —— 原样保留
                out = out.filter { $0.s("board") == main || $0.s("cat_name") == main }
            }
            if !cat.isEmpty {
                out = out.filter { $0.s("board_name") == cat }
            }
            if !type.isEmpty {
                out = out.filter { $0.s("type") == type }
            }
        }
        return out
    }

    // MARK: - 异步计数（§2.6 逐字; 与 list 口径一致, A/B 双口径）

    /// 异步计数 (★ S12-P5 P5.5: **口径必须与 list 完全一致**, 按排序分两种情形):
    ///  A) sort = "date" (post_date 有索引 idx_date, 列表全库扫描) → 全库真值
    ///     COUNT(*) FROM $tt t$w (实测 board_name='国产原创' 全库 72,743 / 395ms,
    ///     异步 + 5min 缓存可接受; 旧版"cat/type 非空 → 派生窗口"分支已删 ——
    ///     那会让显示总数 12,633 < 全库 72,743, 且 hasMore 以 total 为界提前停)。
    ///  B) sort = "updated" (last_checked 无索引, 列表走"最近 2 万帖"派生窗口,
    ///     全库 filesort 实测 1.03s/页不能接受) → 同一派生窗口 COUNT,
    ///     UI 必须标注"仅覆盖最近 2 万帖"。
    /// 失败 -1 (UI 显示"已加载 N 条")。
    /// 注意: 本函数 words(qs) 为空时不返回空, 而是不加任何 q 子句继续计数
    /// （list 中同情形是空页）—— list/count 差异是原样行为, 不要"统一"两者。
    public static func count(
        tt: String, main: String, cat: String, type: String, q: String,
        hasMagnet: Bool, sort: String
    ) async -> Int64 {
        do {
            var whereClause: [String] = []
            var params: [SQLValue?] = []
            if hasMagnet { whereClause.append("magnet_count > 0") }
            if !main.isEmpty {
                // R3 问题 9：与 list() 同口径（COALESCE 主版归一化）。
                whereClause.append("COALESCE(NULLIF(TRIM(board), ''), cat_name) = ?")
                params.append(.string(main))
            }
            if !cat.isEmpty {
                whereClause.append("board_name = ?")
                params.append(.string(cat))
            }
            if !type.isEmpty {
                whereClause.append("`type` = ?")
                params.append(.string(type))
            }
            let qs = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !qs.isEmpty && !isTid(q: qs) {
                let ws = words(q: qs)
                if ws.count == 1 && ws[0].count == 1 {
                    whereClause.append("(title LIKE ? OR `type` LIKE ?)")
                    params.append(.string("%\(ws[0])%"))
                    params.append(.string("%\(ws[0])%"))
                } else {
                    for w in ws {
                        whereClause.append("MATCH(title) AGAINST (? IN NATURAL LANGUAGE MODE)")
                        params.append(.string(w))
                    }
                }
            } else if !qs.isEmpty {
                whereClause.append("tid = ?")
                params.append(.int(Int64(qs) ?? 0))
            }
            let w = whereClause.isEmpty ? "" : " WHERE " + whereClause.joined(separator: " AND ")
            if sort == "updated" {
                // B: 与列表同窗口计数 (复用同一 LIST_DERIVED 常量, 不两处写死)
                return try await Db.scalar(
                    "sht",
                    "SELECT COUNT(*) FROM (SELECT tid FROM \(tt) ORDER BY tid DESC LIMIT \(LIST_DERIVED)) k " +
                        "JOIN \(tt) t ON t.tid = k.tid\(w)",
                    params)
            } else {
                // A: 全库真值 (与列表 idx_date 全库扫描同口径)
                return try await Db.scalar(
                    "sht",
                    "SELECT COUNT(*) FROM \(tt) t\(w)",
                    params)
            }
        } catch {
            return -1   // 计数失败不阻塞, UI 显示"已加载 N 条"
        }
    }
}
