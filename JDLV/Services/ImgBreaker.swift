import Foundation
import JDLVCore

/// 图片 URL 统一入口 + 分桶熔断（对齐 Android core/img/Img.kt）。
///
/// 1. 无效 URL 不发请求（铁律 18）: cover_url 为空或不含库内路径形态 → 拦下,
///    绝不把数据库裸 id 当 URL 发出去（guarded）;
/// 2. 熔断分桶（★ S12-P2 改按图床分桶 app/web/other/sht/ext, 桶间互不影响 ——
///    单一全局窗口会把 spfcas 热评封面被 c0/98t 死图床连坐打空, 即"热评全挂"根因）:
///    60s 窗口失败 ≥30 → 冷却 30s; EXTERNAL 桶弱化: 50 次 / 5s;
/// 3. 单 URL 精确冷却: 同一 URL 连续失败 ≥3 次进入 5 分钟冷却, 冷却期直接拦下
///    （调用方显示占位符）, 避免对已失效 URL 的重试风暴; 成功后自动解除;
/// 4. lastError 诊断: 最近一次失败的 url 前 60 字符 + 异常简名（设置页展示）。
///
/// 常量逐字: FAIL_LIMIT=3 / COOLDOWN_MS=5min / BUCKET_FAIL_LIMIT=30 /
/// BUCKET_WINDOW_MS=60s / BUCKET_COOLDOWN_MS=30s / EXT_FAIL_LIMIT=50 /
/// EXT_COOLDOWN_MS=5s。
final class ImgBreaker {
    static let shared = ImgBreaker()

    // ---- 单 URL 精确冷却 ----
    static let FAIL_LIMIT = 3
    static let COOLDOWN_MS: Int64 = 5 * 60 * 1000

    // ---- ★ S12-P2 (P2.4) 熔断分桶 ----
    static let BUCKET_FAIL_LIMIT = 30
    static let BUCKET_WINDOW_MS: Int64 = 60_000
    static let BUCKET_COOLDOWN_MS: Int64 = 30_000
    /// ★ EXTERNAL 桶不完全屏蔽（外链图一多不能自我熔断）: 阈值 50 次、冷却仅 5s
    static let EXT_FAIL_LIMIT = 50
    static let EXT_COOLDOWN_MS: Int64 = 5_000

    /// url → (次数, 首次失败时刻)（Android fails: HashMap<String, Pair<Int, Long>>）
    private var fails: [String: (count: Int, firstAt: Int64)] = [:]
    /// 桶 → 失败时刻滑动窗口（ArrayDeque 头部淘汰语义）
    private var buckets: [String: [Int64]] = [:]
    private var bucketCooldownUntil: [String: Int64] = [:]
    private var bucketFail: [String: Int64] = [:]
    private var bucketOk: [String: Int64] = [:]

    /// 最近一次失败（url 前 60 字符 + 异常简名）与时刻; 设置页"图床"分组显示
    private(set) var lastError: String = ""
    private(set) var lastErrorAt: Int64 = 0
    private(set) var failCount: Int64 = 0
    private(set) var okCount: Int64 = 0

    private let lock = NSLock()

    private init() {}

    // MARK: - 分桶

    /// URL → 熔断桶（内部用 kindOf 映射; 相对路径 → app）
    func bucketOf(_ raw: String) -> String { CdnRewrite.kindOf(raw).bucket }

    private func bucketLimit(_ b: String) -> Int { b == "ext" ? Self.EXT_FAIL_LIMIT : Self.BUCKET_FAIL_LIMIT }
    private func bucketCooldownMs(_ b: String) -> Int64 { b == "ext" ? Self.EXT_COOLDOWN_MS : Self.BUCKET_COOLDOWN_MS }

    /// 外链判定（ArticleBody 外链占位用）
    static func isExternal(_ url: String) -> Bool { CdnRewrite.kindOf(url) == .external }

    // MARK: - 冷却判定

    /// 单 URL 冷却判定（Android Img.cooled）: 失败 ≥3 次且 5min 内
    func isUrlCooling(_ url: String) -> Bool {
        if url.isEmpty { return false }
        lock.lock(); defer { lock.unlock() }
        guard let f = fails[url] else { return false }
        return f.count >= Self.FAIL_LIMIT && Perf.nowMs() - f.firstAt < Self.COOLDOWN_MS
    }

    /// 桶冷却判定: 该桶冷却期内入口直接拦下（其它桶不受影响）
    func isBucketCooling(_ bucket: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Perf.nowMs() < (bucketCooldownUntil[bucket] ?? 0)
    }

    /// 组合判定（桶冷却 || 单 URL 冷却）—— 图片管线入口用
    func isCooling(url: String) -> Bool {
        isBucketCooling(bucketOf(url)) || isUrlCooling(url)
    }

    // MARK: - 入口守卫（Android Img.guarded / Img.url）

    /// 无效输入不发请求（R4 S1 收紧）：
    ///  - 绝对 URL：仅 https 放行；http 必须显式开启 `allowInsecureHTTP`（设置页红色警告）；
    ///    scheme/host 缺失一律拒绝；
    ///  - 相对路径（库内 /covers|small_covers|samples|avatars|articles/ 形态）：无 scheme，
    ///    最终协议由重写/镜像 host 层决定（缺省补 https），保持原放行分支不变。
    static func guarded(_ raw: String?) -> String? {
        let s = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") {
            return CdnRewrite.imgPathOf(s) != nil ? s : nil
        }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              u.host?.isEmpty == false else { return nil }
        if scheme == "https" { return s }
        if scheme == "http", CdnRewrite.settings().allowInsecureHTTP { return s }
        return nil
    }

    /// 图片 URL（★ S12-P2: 冷却判定按桶, 且用**重写后的最终 URL**; 冷却中的桶返回 ""
    /// → 调用方显示占位符）
    func url(_ raw: String?) -> String {
        guard let g = Self.guarded(raw) else { return "" }
        let u = CdnRewrite.jdbImgUrl(g)
        if u.isEmpty { return "" }
        if isBucketCooling(bucketOf(u)) { return "" }
        if isUrlCooling(u) { return "" }
        return u
    }

    /// 小图封面取哪半: 读设置 coverHalf（0 右半 / 1 左半 / 2 整张; 默认 0, 异常兜 0）
    static func halfMode() -> Int {
        let v = CdnRewrite.settings().coverHalf
        return v == 0 || v == 1 || v == 2 ? v : 0
    }

    // MARK: - 失败/成功上报

    /// 请求失败上报（PosterImage onError 调用; error 供诊断;
    /// ★ S12-P2: 失败同时计入所属图床桶, img.err 打点带 bucket=）。
    /// 单 URL 首失败时刻: 5min 冷却从窗口内**首次**失败起算
    /// （cur == null || now - cur > COOLDOWN_MS 时重置首失败时刻, 否则保留）。
    func recordFailure(_ key: String, error: String? = nil) {
        let now = Perf.nowMs()
        let bk = bucketOf(key)
        lock.lock()
        failCount += 1
        let cur = fails[key]
        let n = (cur?.count ?? 0) + 1
        if cur == nil || now - cur!.firstAt > Self.COOLDOWN_MS {
            fails[key] = (n, now)
        } else {
            fails[key] = (n, cur!.firstAt)
        }
        // 桶级熔断窗口计数（头部淘汰: now - first > 60s 弹出）
        var dq = buckets[bk] ?? []
        dq.append(now)
        while let first = dq.first, now - first > Self.BUCKET_WINDOW_MS {
            dq.removeFirst()
        }
        if dq.count >= bucketLimit(bk) {
            let cd = bucketCooldownMs(bk)
            bucketCooldownUntil[bk] = now + cd
            dq.removeAll()
            Perf.mark("img.bucketCooldown", "bucket=\(bk) on \(cd / 1000)s")
        }
        buckets[bk] = dq
        bucketFail[bk] = (bucketFail[bk] ?? 0) + 1
        lastError = String(key.prefix(60)) + " " + (error ?? "?")
        lastErrorAt = now
        let rate = rateLocked()
        lock.unlock()
        // 堆栈首帧（定位异常来源; 只取一帧, 不含参数）
        let frame = Self.firstCallerFrame()
        Perf.mark("img.err",
                  "key=\(String(key.prefix(60))) bucket=\(bk) err=\(error ?? "-") at=\(frame) rate=\(rate)%")
    }

    /// 请求成功上报（解除冷却; ★ S12-P2: 计入所属桶成功数）
    func recordSuccess(_ key: String) {
        let bk = bucketOf(key)
        lock.lock()
        okCount += 1
        fails.removeValue(forKey: key)
        bucketOk[bk] = (bucketOk[bk] ?? 0) + 1
        lock.unlock()
    }

    /// 重置图片冷却 —— ★ P3.10 大面积裂图自救入口（设置页"图床"分组按钮 /
    /// 卡片失败态"重试"）, 清空失败表与计数; ★ S12-P2: 同时清全部分桶冷却。
    func resetCooling() {
        lock.lock()
        fails.removeAll()
        buckets.removeAll()
        bucketCooldownUntil.removeAll()
        failCount = 0
        okCount = 0
        lock.unlock()
        Perf.mark("img.cooling.reset")
    }

    /// 失败率 %（近累计; 样本 <20 显示 0; >30% 时 UI 提示换镜像）
    func failureRatePct() -> Int {
        lock.lock(); defer { lock.unlock() }
        return rateLocked()
    }

    /// 任务命名对位（= failureRatePct）
    func failureRate() -> Int { failureRatePct() }

    private func rateLocked() -> Int {
        let total = failCount + okCount
        if total < 20 { return 0 }
        return Int(failCount * 100 / total)
    }

    /// ★ S10/S12-P2: 设置页诊断行（最近失败 + 失败率; 文案逐字）。
    /// 桶失败率段: 每桶 "bk:pct", 样本 <10 显示 "-" —— 哪类图床在挂一眼可辨。
    func diagnostic() -> String {
        lock.lock()
        let le = lastError
        let la = lastErrorAt
        let parts = ["app", "web", "other", "sht", "ext"].map { bk -> String in
            let f = bucketFail[bk] ?? 0
            let o = bucketOk[bk] ?? 0
            let tot = f + o
            let pct = tot < 10 ? "-" : "\(f * 100 / tot)%"
            return "\(bk):\(pct)"
        }
        lock.unlock()
        var at = ""
        if la > 0 {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            df.locale = Locale.current
            at = df.string(from: Date(timeIntervalSince1970: Double(la) / 1000))
        }
        return "最近失败: \(le.isEmpty ? "—" : le)\(at) · 失败率 \(failureRatePct())% · 分桶 \(parts.joined(separator: " "))"
    }

    /// Android t.stackTrace.firstOrNull 对位: 取调用方一帧 "模块.方法"
    private static func firstCallerFrame() -> String {
        let syms = Thread.callStackSymbols
        // [0]=callStackSymbols 取值帧 [1]=recordFailure [2]=调用方
        guard syms.count > 2 else { return "-" }
        let s = syms[2]
        guard let bt = s.firstIndex(of: "`") else { return "-" }
        var name = String(s[s.index(after: bt)...])
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        return name.isEmpty ? "-" : name
    }
}
