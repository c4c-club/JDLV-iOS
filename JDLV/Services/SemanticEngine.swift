import Foundation
import JDLVCore

//
//  SemanticEngine —— 两段式语义搜索（P11, App 层: 依赖注入的 Db/Q 与 EmbStore）。
//  对位 Android core/search/SemanticEngine.kt（docs/_extract/03_search_math.md §5
//  与 docs/_extract/12_img_sem.md §8, 查询/候选/打分/文案逐字）。
//
//  四段流程（§5.4 逐字）:
//   ① 候选: SemDataSource.candidates（生产实现 = SELECT tid FROM $tt$w ORDER BY
//      post_date DESC LIMIT ?, 走 idx_date; 筛选在数据源侧组装, 无 FTS/关键词条件 ——
//      语义搜索与关键词搜索是两套独立路）。空 → Result(note="候选为空")。
//   ② 向量: EmbStore 本地命中直接用; 缺失 tid 按 FETCH_BLOCK=2000/块二进制拉取
//      （sht.sem.emb, 不再 HEX）→ EmbStore.putAll 写回（dim = 查询向量维度,
//      fp 空写 "unknown"）; model_fp 变更 → syncModelFp 清表（Android 已知
//      取 key 列 bug 的 iOS 修正见 QSemDataSource.modelFp）。
//   ③ 打分: 4 分块并行点积（块大小 (n/4).coerceAtLeast(1000), TaskGroup）,
//      SemanticMath.score（int8 还原 + 维度不符 -inf）, s >= threshold（闭区间）;
//      合并按块序（对齐 awaitAll().flatten() 稳定语义）, 同分按基础序（确定性 ——
//      Swift 字典无序, 基础序取 tids 顺序 + 拉取块序, Android 是 HashMap 遍历序）。
//   ④ 详情: 本页命中 → SemDataSource.page → associateBy(tid) 后按分数序取行
//      （查不到的 tid 丢弃）+ ShtSearch.fetchCovers。
//
//  口径修正 C-2: total = 命中数（阈值过滤后）, 分页基于命中集
//  pageHits = scored.drop((page-1)*per).take(per)。
//
//  返回键名（对齐 Android Result 字段 + Q.shtSemantic 约定的 VM 映射,
//  见 JDLVCore Q.swift B.25 注释）:
//    "items":     [Row]          —— 按分数降序的本页详情行
//    "covers":    [String: String]（tid → url）
//    "page":      Int
//    "per_page":  Int
//    "total":     Int64          —— = hits（阈值过滤后命中数）
//    "approx":    true
//    "derived":   String         —— note（进度/命中说明）
//    "hits":      Int64          —— 同 total（Android Result.hits 透传）
//    "cand":      Int64          —— 候选数（Android Result.cand 透传）
//    "threshold": Float
//    "note":      String         —— 同 derived（Android Result.note 透传）
//  返回 nil = 模型未就绪/推理失败/空查询 —— 调用方明确提示, **禁止静默降级**。
//
//  Progress 文案逐字（§5.4）: "推理中" / "检测到模型变更, 本地向量已重建" /
//  "拉取向量 X/Y" / "打分中"; note 文案逐字:
//    (fpChanged ? "模型变更已重建 · " : "") + "命中 X / 候选 Y · 阈值 Z · 本地向量 P%"
//    + (fetched > 0 ? " · 新拉 N" : ""); 空候选 note = "候选为空"。
//

/// 查询向量嵌入器（注入; 生产 = OnnxEmbedder, 测试 = 假 embedder）。
public protocol SemEmbedder: AnyObject {
    /// 查询文本 → L2 归一化向量; 模型未就绪/推理失败 → nil。
    func embed(_ text: String) async -> [Float]?
}

/// 进度回调载荷（Android Progress(phase) 对位; phase 文案逐字）。
public struct SemProgress: Equatable, Sendable {
    public let phase: String
    public init(_ phase: String) { self.phase = phase }
}

/// 语义搜索数据源（注入协议 —— 生产实现包 Db/Q; 测试注入假源）。
public protocol SemDataSource: AnyObject {
    /// 候选 tid（sht.sem.cand; 含筛选与 LIMIT :cand, ORDER BY post_date DESC）
    func candidates(cand: Int) async throws -> [Int64]
    /// int8 向量二进制拉取（单次 IN 查询; sht.sem.emb; emb 非 blob 的行静默跳过）
    func embs(tids: [Int64]) async throws -> [Int64: Data]
    /// 远程模型指纹（修正口径取 value 列; 失败/空 → nil 不阻塞 —— Android bug 修复见 QSemDataSource）
    func modelFp() async -> String?
    /// 本页命中详情行（行含 tid 列; 排序由引擎按分数序恢复）
    func page(hits: [Int64]) async throws -> [Row]
}

public final class SemanticEngine {

    /// 向量缺失拉取分块大小（§5.2 常量逐字）
    public static let FETCH_BLOCK = 2000

    private let dataSource: SemDataSource
    /// 本地 int8 向量表（nil = 无本地缓存 —— 直连远程）
    private let store: EmbStore?

    public init(dataSource: SemDataSource, embStore: EmbStore?) {
        self.dataSource = dataSource
        self.store = embStore
    }

    // MARK: - search

    @discardableResult
    public func search(
        embedder: SemEmbedder,
        q: String, page: Int = 1, per: Int = 20,
        cand: Int = 3000, threshold: Float = 0.10,
        onProgress: ((SemProgress) async -> Void)? = nil
    ) async throws -> [String: Any]? {
        let qs = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if qs.isEmpty { return nil }
        let t0 = Perf.begin("semantic.search")
        await onProgress?(SemProgress("推理中"))
        guard let qv = await embedder.embed(qs) else {
            return nil   // 模型未就绪/推理失败 → null, 调用方禁止静默降级
        }
        let dim = qv.count

        // ---- ① 候选 tid ----
        let tids = try await dataSource.candidates(cand: cand)
        if tids.isEmpty {
            Perf.end("semantic.search", t0, "cand=0")
            return Self.result(items: [], covers: [:], page: page, per: per,
                               hits: 0, cand: 0, threshold: threshold, note: "候选为空")
        }

        // ---- ② 向量: 本地优先 + 缺失二进制拉取 (2000/块) ----
        let fp = await dataSource.modelFp() ?? ""
        var fpChanged = false
        if let store = store {
            // 对齐 Android EmbStore.syncModelFp 语义: fp 空 → false 不动（不阻塞）;
            // 首次写入（kv 无指纹）→ false（iOS EmbStore.syncModelFp 对此返回 true,
            // 由引擎侧守卫; 首装时表本就为空, putAll 会落 kv.model_fp）;
            // 变化 → clear + true。
            if !fp.isEmpty {
                let old = try store.modelFp()
                if old != nil {
                    fpChanged = try store.syncModelFp(fp)
                }
            }
            if fpChanged {
                await onProgress?(SemProgress("检测到模型变更, 本地向量已重建"))
            }
        }
        let records = try store?.getExisting(tids) ?? [:]
        var blobById: [Int64: Data] = [:]
        var ordered: [(Int64, Data)] = []   // 确定性基础序: tids 序（本地）+ 拉取块序（远程）
        var localCount = 0
        for tid in tids {
            guard let rec = records[tid], blobById[tid] == nil else { continue }
            blobById[tid] = rec.emb
            ordered.append((tid, rec.emb))
            localCount += 1
        }
        let missing = tids.filter { blobById[$0] == nil }
        var fetched = 0
        var i = 0
        while i < missing.count {
            let end = min(i + Self.FETCH_BLOCK, missing.count)
            let chunk = Array(missing[i..<end])
            await onProgress?(SemProgress("拉取向量 \(fetched + chunk.count)/\(missing.count)"))
            let got = try await dataSource.embs(tids: chunk)
            for tid in chunk {
                if let blob = got[tid] {
                    blobById[tid] = blob
                    ordered.append((tid, blob))
                }
            }
            fetched += got.count
            if !got.isEmpty, let store = store {
                try store.putAll(got, dim: Int32(dim), fp: fp.isEmpty ? "unknown" : fp)
            }
            i += Self.FETCH_BLOCK
        }

        // ---- ③ 打分: 4 分块并行（TaskGroup; 块大小 (n/4).coerceAtLeast(1000)）----
        await onProgress?(SemProgress("打分中"))
        let chunkSize = max(ordered.count / 4, 1000)
        var scored: [(Int64, Float)] = []
        if chunkSize > 0 && !ordered.isEmpty {
            let chunkCount = (ordered.count + chunkSize - 1) / chunkSize
            let parts: [[(Int64, Float)]] = await withTaskGroup(
                of: (Int, [(Int64, Float)]).self) { group in
                var results = [[(Int64, Float)]](repeating: [], count: chunkCount)
                var idx = 0
                var ci = 0
                while idx < ordered.count {
                    let end = min(idx + chunkSize, ordered.count)
                    let slice = Array(ordered[idx..<end])
                    let qvCopy = qv
                    let th = threshold
                    let myCi = ci
                    group.addTask {
                        var out: [(Int64, Float)] = []
                        out.reserveCapacity(slice.count)
                        for (tid, blob) in slice {
                            let s = SemanticMath.score(query: qvCopy, blob: blob)
                            if s >= th { out.append((tid, s)) }
                        }
                        return (myCi, out)
                    }
                    idx = end
                    ci += 1
                }
                for await (doneCi, part) in group {
                    results[doneCi] = part   // 按块序回填 → 对齐 awaitAll().flatten()
                }
                return results
            }
            for part in parts {
                scored.append(contentsOf: part)
            }
        }
        // 稳定降序（Kotlin sortedByDescending 稳定; 同分保持基础序 → offset 平局裁决）
        let sorted = scored.enumerated()
            .sorted { a, b in
                a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
            }
            .map { $0.element }

        let hits = sorted.count
        // ---- ④ 本页命中 → 详情 + 封面 ----
        let pageHits = Array(sorted.dropFirst((page - 1) * per).prefix(per))
        var items: [Row] = []
        var covers: [String: String] = [:]
        if !pageHits.isEmpty {
            let hitIds = pageHits.map { $0.0 }
            let rows = try await dataSource.page(hits: hitIds)
            // associateBy { tid }（Kotlin 语义: 重复键取后写）
            var byTid: [String: Row] = [:]
            for r in rows {
                byTid[r.s("tid")] = r
            }
            // 按分数序返回（详情查不到的 tid 丢弃）
            for h in pageHits {
                if let row = byTid[String(h.0)] {
                    items.append(row)
                }
            }
            covers = try await ShtSearch.fetchCovers(
                tids: hitIds.map { String($0) })
        }
        let localPct = localCount * 100 / tids.count   // 整数除法（对齐 Android）
        var note = (fpChanged ? "模型变更已重建 · " : "")
            + "命中 \(hits) / 候选 \(tids.count) · 阈值 \(threshold) · 本地向量 \(localPct)%"
        if fetched > 0 {
            note += " · 新拉 \(fetched)"
        }
        Perf.end("semantic.search", t0,
                 "cand=\(tids.count) hits=\(hits) local=\(localPct)% fetched=\(fetched) dim=\(dim)")
        return Self.result(items: items, covers: covers, page: page, per: per,
                           hits: hits, cand: tids.count, threshold: threshold, note: note)
    }

    // MARK: - 结果映射

    /// Android Result + Q.shtSemantic VM 映射键（类头注释见键名清单）。
    private static func result(
        items: [Row], covers: [String: String], page: Int, per: Int,
        hits: Int, cand: Int, threshold: Float, note: String
    ) -> [String: Any] {
        return [
            "items": items,
            "covers": covers,
            "page": page,
            "per_page": per,
            "total": Int64(hits),
            "approx": true,
            "derived": note,
            "hits": Int64(hits),
            "cand": Int64(cand),
            "threshold": threshold,
            "note": note,
        ]
    }
}

// MARK: - 生产数据源（包 Db/Q）

/// 生产 SemDataSource: 候选/向量/指纹/详情四条 SQL 走 Db 门面 + SqlPolicy。
/// 筛选子句与 Android §5.4 逐字（无 t. 前缀, 无 FTS/关键词条件）。
public final class QSemDataSource: SemDataSource {

    public let tt: String
    public let listCols: String
    public let main: String
    public let cat: String
    public let type: String
    public let hasMagnet: Bool

    private init(tt: String, listCols: String,
                 main: String, cat: String, type: String, hasMagnet: Bool) {
        self.tt = tt
        self.listCols = listCols
        self.main = main
        self.cat = cat
        self.type = type
        self.hasMagnet = hasMagnet
    }

    /// 异步工厂（表名/列名探测在 Db）。
    public static func make(
        main: String = "", cat: String = "", type: String = "", hasMagnet: Bool = false
    ) async -> QSemDataSource {
        let tt = await Db.tableOf("sht", "threads")
        let cols = await listCols(tt)
        return QSemDataSource(tt: tt, listCols: cols,
                              main: main, cat: cat, type: type, hasMagnet: hasMagnet)
    }

    /// 复刻 Q.shtListCols（internal 不可见 —— 12 列白名单逐字; ★ last_checked 必须在
    /// SELECT 的约束与列表 keyset 无关, 此处保留同一列族）
    private static func listCols(_ tt: String) async -> String {
        let want = [
            "tid", "title", "cat_name", "board", "board_name", "type",
            "post_date", "last_checked", "magnet_count", "article_words", "paywalled", "author",
        ]
        let have = await Db.cols("sht", tt)
        let cols = want.filter { have.contains($0) }
        if cols.isEmpty { return "tid, title, post_date" }
        return cols.joined(separator: ", ")
    }

    // MARK: SemDataSource

    public func candidates(cand: Int) async throws -> [Int64] {
        // Android §5.4 ①: `SELECT tid FROM $tt$w ORDER BY post_date DESC LIMIT ?`
        // （模板族 sht.sem.cand; 走 idx_date, 有筛选时索引序扫描+过滤）
        var whereClause: [String] = []
        var params: [SQLValue?] = []
        if hasMagnet { whereClause.append("magnet_count > 0") }
        if !main.isEmpty {
            whereClause.append("(board = ? OR (board IS NULL AND cat_name = ?))")
            params.append(.string(main))
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
        let w = whereClause.isEmpty ? "" : " WHERE " + whereClause.joined(separator: " AND ")
        let sql = "SELECT tid FROM \(tt)\(w) ORDER BY post_date DESC LIMIT ?"
        params.append(.int(Int64(cand)))
        let rows = try await Db.query("sht", sql, params)
        // Android: mapNotNull { it.s("tid").toLongOrNull() }
        return rows.compactMap { Int64($0.s("tid")) }
    }

    public func embs(tids: [Int64]) async throws -> [Int64: Data] {
        if tids.isEmpty { return [:] }
        // Android §5.4 ②: `SELECT tid, emb FROM sht_thread_embs WHERE tid IN ($ph)`
        // （二进制 blob, 不再 HEX; 模板族 sht.sem.emb）
        let ph = tids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT tid, emb FROM sht_thread_embs WHERE tid IN (\(ph))"
        let rows = try await Db.query(
            "sht", sql, tids.map { SQLValue?.some(.string(String($0))) })
        var out: [Int64: Data] = [:]
        for r in rows {
            guard let tid = Int64(r.s("tid")) else { continue }
            guard case .data(let blob)? = r["emb"] else { continue }  // 非 blob 静默跳过
            out[tid] = blob
        }
        return out
    }

    public func modelFp() async -> String? {
        // iOS 修正口径（12 §8.3: Android 取到 key 列的 bug）:
        //   SELECT value FROM sht_sem_meta WHERE key = 'model_fp' LIMIT 1
        // SqlPolicy 现登记模板为 `select .* from (sht_)?sem_meta limit 1`（无 WHERE 形式,
        // 且本阶段禁改 SqlPolicy）→ 运行时探测: WHERE 形式合规则用之; 否则退化为
        // `SELECT value FROM \(tt) LIMIT 1`（远程实况仅一行 (model_fp, '…|384'),
        // 同样取 value 列 —— 仍修正 Android 读 key 列的 bug; 模板登记后自动升级）。
        let tt = await Db.tableOf("sht", "sem_meta")
        let whereSql = "SELECT value FROM \(tt) WHERE key = 'model_fp' LIMIT 1"
        if SqlPolicy.check("sht", whereSql) == nil {
            return await Self.fpQuery(whereSql)
        }
        return await Self.fpQuery("SELECT value FROM \(tt) LIMIT 1")
    }

    private static func fpQuery(_ sql: String) async -> String? {
        do {
            let rows = try await Db.query("sht", sql, [])
            guard let first = rows.first else { return nil }
            let v = first.s("value")
            return v.isEmpty ? nil : v
        } catch {
            return nil   // 失败不阻塞（Android catch → ""）
        }
    }

    public func page(hits: [Int64]) async throws -> [Row] {
        if hits.isEmpty { return [] }
        // Android §5.4 ④: `SELECT $listCols FROM $tt WHERE tid IN ($ph)`。
        // 该形态尚未在 SqlPolicy 登记（enforce=true 会拒）→ 运行时探测:
        // 合规（模板登记后）走逐字 IN 查询; 否则逐 tid 走 sht.detail.main
        // （SELECT * FROM $tt WHERE tid = ?, PK 直达 ≤ per 次; 行为等价 ——
        //  列为全列超集, 引擎按 tid associateBy + 分数序取行）。
        let ph = hits.map { _ in "?" }.joined(separator: ",")
        let inSql = "SELECT \(listCols) FROM \(tt) WHERE tid IN (\(ph))"
        if SqlPolicy.check("sht", inSql) == nil {
            let rows = try await Db.query(
                "sht", inSql, hits.map { SQLValue?.some(.string(String($0))) })
            return rows
        }
        var rows: [Row] = []
        rows.reserveCapacity(hits.count)
        for tid in hits {
            let sql = "SELECT * FROM \(tt) WHERE tid = ?"
            rows.append(contentsOf: try await Db.query(
                "sht", sql, [.string(String(tid))]))
        }
        return rows
    }
}

// MARK: - App 装配便捷入口（Q.shtSemantic 对位; ORT 在 App 层）

extension SemanticEngine {

    /// 生产检索（Q.shtSemantic 的委托目标; 模型未导入 → nil, 上层抛
    /// SemanticUnavailableError 提示, 禁止静默降级）。
    public static func searchProduction(
        main: String = "", cat: String = "", type: String = "", hasMagnet: Bool = false,
        q: String, page: Int = 1, per: Int = 20,
        cand: Int = 3000, threshold: Float = 0.10,
        embStore: EmbStore?,
        embedder: SemEmbedder,
        onProgress: ((SemProgress) async -> Void)? = nil
    ) async throws -> [String: Any]? {
        let dataSource = await QSemDataSource.make(
            main: main, cat: cat, type: type, hasMagnet: hasMagnet)
        let engine = SemanticEngine(dataSource: dataSource, embStore: embStore)
        return try await engine.search(
            embedder: embedder, q: q, page: page, per: per,
            cand: cand, threshold: threshold, onProgress: onProgress)
    }
}
