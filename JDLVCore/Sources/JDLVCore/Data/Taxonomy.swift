import Foundation

// Taxonomy / 分类聚合 / 标签索引（对齐 Android data/Q.kt 的 taxonomy()/filters()/
// tagsCategories 与标签索引状态字段）。
//
// 本阶段（P4）：remote 查询 + fallback 结构。四级降级（remote→stale→fallback→assets）
// 中 QCache 接线与 assets 资源读取在 P5 —— assets 通过 `Q.tagsIndexDataProvider`
// 注入（App/缓存层提供 Bundle 资源），nil = 不可用 → TagIndex.EMPTY。
//
// SQL 逐字（模板 id 标注在各查询处）。taxonomy 回退 codes 的 SQL 在 SqlPolicy
// 无登记模板（jdb.filters.letters 要求别名 letter），guard 拒绝后由 q() 吞掉 →
// 恒返回空列表 —— 与 Android enforce 行为完全一致（Q.kt 已知问题，刻意保留）。

extension Q {

    // MARK: - 标签索引状态（Android Q @Volatile 字段对位）

    private static let tagLock = NSLock()
    private static var tagIndexValue: TagIndex = .EMPTY
    private static var assetsTagIndexValue: TagIndex = .EMPTY
    private static var assetsLoaded = false
    private static var remoteTagCacheTs: Int64 = 0
    private static var remoteTagCacheValue: TagIndex = .EMPTY

    /// assets tags_index.json 数据源（P5 由 App/缓存层注入；nil = 不可用 → EMPTY）。
    /// Android 对位：Db.appCtx.assets.open("tags_index.json")。
    public static var tagsIndexDataProvider: (() -> Data?)?

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - B.2 tagIdByName / tagNameOf（标签索引，无 SQL）

    /// 标签名 → tag_id（assets + 24h 内远程 taxonomy 叠加，远程优先）。
    /// 映射不到返回 nil（调用方不得退化为 tag_name=? 全表扫）。
    public static func tagIdByName(_ name: String) -> String? {
        ensureTagIndex()
        return tagIndexValue.idOf(name)
    }

    /// tag_id → 标签名（查不到返回 nil，UI 显示 #id）。
    public static func tagNameOf(_ id: String) -> String? {
        ensureTagIndex()
        return tagIndexValue.nameOf(id)
    }

    /// remoteTagCache 非空且 24h 内才有效。
    private static func validRemoteTagIndex() -> Bool {
        !remoteTagCacheValue.isEmpty() && nowMs() - remoteTagCacheTs < 24 * 3600 * 1000
    }

    /// assets tags_index.json 至少加载一次（解析失败 → EMPTY，assetsLoaded 仍置 true）；
    /// 随后叠加 24h 内的远程 taxonomy（TagIndex.merge(assets, remote)，远程优先）。
    private static func ensureTagIndex() {
        tagLock.lock()
        defer { tagLock.unlock() }
        if !assetsLoaded {
            assetsLoaded = true
            if let data = tagsIndexDataProvider?(), let pairs = parseTagsIndex(data) {
                assetsTagIndexValue = TagIndex.of(pairs)
            } else {
                assetsTagIndexValue = .EMPTY
            }
        }
        tagIndexValue = TagIndex.merge(
            assetsTagIndexValue,
            validRemoteTagIndex() ? remoteTagCacheValue : nil)
    }

    /// taxonomy 的 tags 行进远程标签缓存（Android rememberRemoteTags 对位）。
    static func rememberRemoteTags(_ tags: [Row]) {
        let pairs = tags
            .map { ($0.s("id"), $0.s("name")) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
        tagLock.lock()
        remoteTagCacheTs = nowMs()
        remoteTagCacheValue = TagIndex.of(pairs)
        tagLock.unlock()
        ensureTagIndex()
    }

    /// tags_index.json（[{category, tags:[{id,name}]}]）→ (id, name) 对。
    private static func parseTagsIndex(_ data: Data) -> [(String, String)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var pairs: [(String, String)] = []
        for cat in root {
            guard let tags = cat["tags"] as? [[String: Any]] else { continue }
            for t in tags {
                let id = jstr(t["id"])
                let nm = jstr(t["name"])
                if !id.isEmpty && !nm.isEmpty { pairs.append((id, nm)) }
            }
        }
        return pairs
    }

    /// org.json optString 语义对位（非空标量 → 字符串，null/缺列 → ""）。
    private static func jstr(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return String(d) }
        return ""
    }

    // MARK: - B.3 taxonomy〔公开〕（jdb）
    // 模板 id：makers → jdb.tax.makers(small)；codes → jdb.tax.codes(small)；
    // tags → jdb.tax.tags(derived)；years → jdb.filters.years(idx)；
    // 回退 makers → jdb.filters.makers(derived)；回退 codes → 无匹配模板（guard 拒绝 → q() 吞掉 → 恒空）。

    public static func taxonomy() async -> [String: Any] {
        // 每段独立容错，吞一切异常（Android 局部 q(sql) 对位）
        func q(_ sql: String) async -> [Row] {
            do { return try await Db.query("jdb", sql) } catch { return [] }
        }
        // 四段并行
        async let makers0 = q("SELECT id, name, videos_count c FROM makers ORDER BY videos_count DESC LIMIT 500")
        async let codes0 = q("SELECT id, name, videos_count c FROM codes ORDER BY videos_count DESC LIMIT 3000")
        async let tagsF = q(
            "SELECT tag_id id, tag_name name, COUNT(*) c FROM " +
                "(SELECT id FROM movies ORDER BY release_date DESC LIMIT 20000) k " +
                "JOIN movie_tags t ON t.movie_id = k.id " +
                "GROUP BY tag_id, tag_name ORDER BY c DESC LIMIT 500")
        async let yearsF = q(
            "SELECT year, COUNT(*) c FROM movies WHERE year IS NOT NULL " +
                "GROUP BY year ORDER BY year DESC LIMIT 40")

        var makers = await makers0
        var codes = await codes0
        var fallback = false
        if makers.isEmpty {
            fallback = true
            // 回退 makers（索引表为空时）
            makers = await q(
                "SELECT maker_id id, maker_name name, COUNT(*) c FROM " +
                    "(SELECT maker_id, maker_name FROM movies ORDER BY release_date DESC LIMIT 20000) k " +
                    "WHERE maker_id IS NOT NULL GROUP BY maker_id, maker_name ORDER BY c DESC LIMIT 500")
        }
        if codes.isEmpty {
            fallback = true
            // 回退 codes（索引表为空时）——★ 已知问题（与 Android 逐字一致）：
            // 该 SQL 无 SqlPolicy 登记模板（jdb.filters.letters 要求字面
            // "select number_letter letter,"），guard 抛 SqlPolicyViolation 被 q() 吞掉
            // → 恒返回空列表。
            codes = await q(
                "SELECT number_letter id, number_letter name, COUNT(*) c FROM " +
                    "(SELECT number_letter FROM movies ORDER BY release_date DESC LIMIT 20000) k " +
                    "WHERE number_letter IS NOT NULL GROUP BY number_letter ORDER BY c DESC LIMIT 3000")
        }
        let tags = await tagsF
        let years = await yearsF
        rememberRemoteTags(tags)
        return [
            "makers": makers, "codes": codes, "tags": tags,
            "years": years, "fallback": fallback, "ts": nowMs(),
        ]
    }

    // MARK: - B.15 filters〔公开〕（jdb）
    // 模板 id：years → jdb.filters.years(idx)；letters → jdb.filters.letters(derived)；
    // makers → jdb.filters.makers(derived)。

    public static func filters() async -> [String: Any] {
        func q(_ sql: String) async -> [Row] {
            do { return try await Db.query("jdb", sql) } catch { return [] }
        }
        let have = await Db.cols("jdb", "movies")
        // years / letters（列存在才查；列探测失败时与 movieCols 同宽容策略仍查询，
        // 列缺失时 SQL 报错由 q() 吞掉 → 空列表）
        var years: [Row] = []
        if have.isEmpty || have.contains("year") {
            years = await q(
                "SELECT year, COUNT(*) c FROM movies WHERE year IS NOT NULL " +
                    "GROUP BY year ORDER BY year DESC LIMIT 40")
        }
        var letters: [Row] = []
        if have.isEmpty || have.contains("number_letter") {
            letters = await q(
                "SELECT number_letter letter, COUNT(*) c FROM " +
                    "(SELECT number_letter FROM movies ORDER BY release_date DESC LIMIT 20000) k " +
                    "WHERE number_letter IS NOT NULL GROUP BY number_letter ORDER BY c DESC LIMIT 60")
        }
        // makers（总是查，近期 2 万部内聚合近似）
        let makers = await q(
            "SELECT maker_id id, maker_name name, COUNT(*) c FROM " +
                "(SELECT maker_id, maker_name FROM movies ORDER BY release_date DESC LIMIT 20000) k " +
                "WHERE maker_id IS NOT NULL GROUP BY maker_id, maker_name ORDER BY c DESC LIMIT 60")
        let cats = tagsCategories()
        // ★ S15-08 拍平：id/name 非空 → {id,name,c:0}，按 id 去重
        var flat: [[String: Any]] = []
        var seen = Set<String>()
        for c in cats {
            guard let tagList = c["tags"] as? [[String: Any]] else { continue }
            for t in tagList {
                guard let id = t["id"] as? String, let nm = t["name"] as? String,
                      !id.isEmpty, !nm.isEmpty else { continue }
                if seen.contains(id) { continue }
                seen.insert(id)
                flat.append(["id": id, "name": nm, "c": Int64(0)])
            }
        }
        return [
            "years": years, "months": Array(1...12), "letters": letters,
            "makers": makers, "categories": cats, "tags": flat,
        ]
    }

    // MARK: - tagsCategories〔私有〕（assets tags_index.json，无 SQL）

    /// 分类白名单（逐字）
    private static let CAT_WHITELIST: Set<String> = ["主題", "角色", "服裝", "體型", "行爲", "玩法", "類別"]

    /// 解析 assets tags_index.json，保留分类白名单；
    /// 输出 [{key: category, name: category, tags: [{id,name}...]}]；失败 → 空列表。
    private static func tagsCategories() -> [[String: Any]] {
        guard let data = tagsIndexDataProvider?(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [[String: Any]] = []
        for cat in root {
            let category = jstr(cat["category"])
            guard CAT_WHITELIST.contains(category) else { continue }
            guard let tags = cat["tags"] as? [[String: Any]] else { continue }
            var list: [[String: Any]] = []
            for t in tags {
                let id = jstr(t["id"])
                let nm = jstr(t["name"])
                if !id.isEmpty && !nm.isEmpty {
                    list.append(["id": id, "name": nm])
                }
            }
            out.append(["key": category, "name": category, "tags": list])
        }
        return out
    }
}
