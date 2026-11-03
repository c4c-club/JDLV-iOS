import Foundation
import JDLVCore

/**
 * 图床嗅探单飞 worker（对齐 Android core/img/CdnSniffer.kt + data/CdnRewrite.sniff）。
 *
 * 旧病灶 (R1/R11): 三路并发嗅探互不知晓、无取消、无超时, 且其中一路在设置写锁内
 * —— 嗅探期间所有设置写入排队 ("改设置没反应")。
 *
 * 现状:
 *  - 单飞: 同一时刻最多一个嗅探; 同 URL 运行中重复请求返回 false; 不同 URL 先取消旧任务;
 *  - 超时: 整体预算 25s（内部单次 HTTP 调用另有 8s 超时, 对齐 sniffClient callTimeout）,
 *    ≥24.5s 判定超时, 超时写 state.error;
 *  - 取消: cancel() 置 error="已取消"（在飞 HTTP 调用受 8s 超时约束自然结束）;
 *  - 状态: state 供设置页订阅（嗅探中/成功 host/失败原因）, 嗅探期间其它设置不受影响;
 *  - 打点: cdn.sniff.start / cdn.sniff.end / cdn.sniff.timeout（不含凭证, 只含 host）;
 *  - 持久化: saveSniffed 只更新内存 CdnRewrite.shtHost, sht_mirror_host 落盘由调用方
 *    SettingsStore 负责（★ S14-P1 数据层不写设置）。
 *
 * 嗅探三阶段（Android CdnRewrite.sniff 逐字流程）:
 *  0. 主站抓取 + _safe cookie 确认页自动通过;
 *  1. 收集候选: IMG_RE 全图 host + 主站 host + THREAD_RE 前 8 → 归一 → distinct 3 帖;
 *  2. 阶段 A: HTML 完整图 distinct 前 14 条直连验魔数;
 *  3. 阶段 B: 库内 thread_images 前 5 条路径 × 候选 host 探测, 首个成功即返回;
 *     ★ iOS 修复: 候选 host 补 https:// 前缀 —— Android 阶段 B 拼出无 scheme URL
 *     实际永远失败（死代码）, 嗅探靠阶段 A/C 生效;
 *  4. 阶段 C: HTML 验证结果优先非主站 host。
 */
final class CdnSniffer {
    static let shared = CdnSniffer()

    /// 整体预算 25s
    static let TIMEOUT_MS: Int64 = 25_000

    struct State: Equatable {
        var running: Bool = false
        var kind: String = ""
        var url: String = ""
        var host: String? = nil
        var error: String = ""
        var startedAt: Int64 = 0
        var doneAt: Int64 = 0
    }

    private let lock = NSLock()
    private var _state = State()
    private var job: Task<Void, Never>?

    /// 当前状态（设置页订阅; 或经 onStateChange 回调驱动 UI 刷新）
    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// 状态变化回调（设置页接线用）
    var onStateChange: ((State) -> Void)?

    private init() {}

    /// hostOf(u) = u.substringAfter("://").substringBefore('/').take(60)（打点用, 不含凭证）
    private static func hostOf(_ u: String) -> String {
        String(CdnRewrite.substringBefore(CdnRewrite.substringAfter(u, "://"), "/").prefix(60))
    }

    /**
     * 单飞请求。返回 false = 已有同 URL 嗅探在跑（调用方无需重复触发）。
     * 不同 URL → 先取消旧任务再启动新嗅探。同步判定, 状态即改即见。
     */
    @discardableResult
    func request(kind: String, siteUrl: String) -> Bool {
        let url = siteUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return false }
        lock.lock()
        if _state.running && _state.url == url {
            lock.unlock()
            return false
        }
        if _state.running {
            job?.cancel()
            job = nil
        }
        let t0 = Perf.nowMs()
        _state = State(running: true, kind: kind, url: url, host: nil, error: "",
                       startedAt: t0, doneAt: 0)
        let snapshot = _state
        let cb = onStateChange
        lock.unlock()
        cb?(snapshot)
        Perf.mark("cdn.sniff.start", "kind=\(kind) host=\(Self.hostOf(url))")
        let j = Task { [weak self] in
            await self?.runSniffJob(kind: kind, url: url, startedAt: t0)
        }
        lock.lock()
        job = j
        lock.unlock()
        return true
    }

    /// 取消当前嗅探（无运行中任务则忽略）; UI 显示"已取消"
    func cancel() {
        lock.lock()
        let cur = _state
        job?.cancel()
        job = nil
        if cur.running {
            _state = State(running: false, kind: cur.kind, url: cur.url, host: nil,
                           error: "已取消", startedAt: cur.startedAt, doneAt: Perf.nowMs())
        }
        let snapshot = _state
        let cb = onStateChange
        lock.unlock()
        if cur.running {
            cb?(snapshot)
            Perf.mark("cdn.sniff.end", "kind=\(cur.kind) ok=0 cancelled=1")
        }
    }

    private func setState(_ s: State) {
        lock.lock()
        _state = s
        let cb = onStateChange
        lock.unlock()
        cb?(s)
    }

    private func runSniffJob(kind: String, url: String, startedAt: Int64) async {
        let r = await Self.withTimeout(ms: Self.TIMEOUT_MS) {
            await Self.sniff(kind: kind, siteUrl: url)
        }
        guard !Task.isCancelled else { return }   // cancel() 已置 "已取消", 不覆盖
        let ms = Perf.nowMs() - startedAt
        if let host = r.value {
            setState(State(running: false, kind: kind, url: url, host: host, error: "",
                           startedAt: startedAt, doneAt: Perf.nowMs()))
        } else {
            // ≥ 25s - 500ms 判定超时（对齐 Android）
            let timedOut = ms >= Self.TIMEOUT_MS - 500 || r.timedOut
            if timedOut {
                Perf.mark("cdn.sniff.timeout", "kind=\(kind) ms=\(ms)")
            }
            setState(State(running: false, kind: kind, url: url, host: nil,
                           error: timedOut ? "嗅探超时 (25s)"
                                           : "未嗅探到可用图床 (确认地址可达/代理可用)",
                           startedAt: startedAt, doneAt: Perf.nowMs()))
        }
        Perf.mark("cdn.sniff.end",
                  "kind=\(kind) ok=\(r.value != nil ? "true" : "false") ms=\(ms) host=\(Self.hostOf(url))")
    }

    // MARK: - 超时包装（withTimeoutOrNull 对位）

    private enum Timed<T> { case value(T); case timeout }

    private static func withTimeout<T: Sendable>(
        ms: Int64, _ op: @escaping @Sendable () async -> T
    ) async -> (value: T?, timedOut: Bool) {
        await withTaskGroup(of: Timed<T>.self) { group in
            group.addTask { await Timed.value(op()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return Timed<T>.timeout
            }
            var out: (value: T?, timedOut: Bool) = (nil, false)
            for await r in group {
                switch r {
                case .value(let v): out = (v, false)
                case .timeout: out = (nil, true)
                }
                group.cancelAll()
                break
            }
            return out
        }
    }

    // MARK: - 正则（逐字）

    static let IMG_RE = try! NSRegularExpression(
        pattern: #"(?:https?:)?//[A-Za-z0-9.\-]+(?:/[^"'<>\s]*?)?\.(?:jpe?g|png|webp|gif|avif)"#,
        options: [.caseInsensitive])
    static let THREAD_RE = try! NSRegularExpression(
        pattern: #"(?:https?://[^/"'<>\s]+)?/(?:thread-(\d+)-\d+-\d+\.html|forum\.php\?mod=viewthread&(?:amp;)?tid=(\d+))"#)
    static let SAFEID_RE = try! NSRegularExpression(
        pattern: #"var\s+safeid\s*=\s*'([^']+)'"#)

    // MARK: - 嗅探算法（CdnRewrite.sniff 移植）

    /// 98t 线路嗅探: 主站 (自动补协议, 确认页自动过 _safe cookie) → 最近帖子 → 图床验证
    static func sniff(kind: String, siteUrl: String) async -> String? {
        if kind != "sht" { return nil }
        let base = CdnRewrite.normalizeUrl(siteUrl)
        if base.isEmpty { return nil }
        do {
            var html = await fetchHtml(base)
            let safeid = CdnRewrite.group(SAFEID_RE, html, 1) ?? ""
            if !safeid.isEmpty {
                html = await fetchHtml(base, cookie: "_safe=\(safeid)")   // 确认页自动过安全 cookie
            }
            var candidates: [String] = []      // LinkedHashSet 语义: 插入序去重
            var fullImgs: [String] = []
            collectImageHosts(html, &candidates, &fullImgs)
            appendUnique(&candidates, CdnRewrite.hostOnly(base))
            // THREAD_RE.findAll.take(8) → 归一 → distinct.take(3) → 逐帖收集
            let threadUrls = CdnRewrite.matchValue(THREAD_RE, html).prefix(8).map { raw -> String in
                if raw.hasPrefix("http") { return raw }
                if raw.hasPrefix("//") { return "https:" + raw }
                if raw.hasPrefix("/") { return base + raw }
                return "\(base)/\(raw)"
            }
            var seen = Set<String>()
            for tu in threadUrls where !seen.contains(tu) {
                seen.insert(tu)
                if seen.count > 3 { break }
                collectImageHosts(await fetchHtml(tu), &candidates, &fullImgs)
            }
            // 阶段 A: HTML 完整图直连验魔数（distinct 前 14 条）
            var htmlVerified: [String] = []
            var seenFull = Set<String>()
            for u in fullImgs {
                if seenFull.contains(u) { continue }
                seenFull.insert(u)
                if seenFull.count > 14 { break }
                if await probeImage(u) {
                    let h = CdnRewrite.hostOnly(u)
                    if !htmlVerified.contains(h) { htmlVerified.append(h) }
                }
            }
            // 阶段 B: 库内图片原路径 + 候选 host（首个成功即返回）
            // ★ iOS 修复: 候选 host 补 https:// 前缀（Android 无 scheme → OkHttp
            //   Request.Builder().url() 抛 IAE 被吞 → 阶段 B 永远失败, 死代码）
            let testPaths = await testImageUrls()
            if !testPaths.isEmpty {
                for cand in candidates {
                    for tp in testPaths {
                        if await probeImage("https://" + cand + tp) {
                            return saveSniffed(cand)
                        }
                    }
                }
            }
            // 阶段 C: HTML 验证结果（优先非主站 host）
            let site = CdnRewrite.hostOnly(base)
            let pick = htmlVerified.first { $0 != site } ?? htmlVerified.first
            if let p = pick { return saveSniffed(p) }
            // Android: Log.w("sniff[sht] no usable cdn host (base=$base)")
            return nil
        } catch {
            // Android: Log.w("sniff[sht] failed: $e")
            return nil
        }
    }

    /// saveSniffed: 只更新内存 shtHost 并返回; sht_mirror_host 持久化由调用方
    /// SettingsStore 负责（★ S14-P1）
    private static func saveSniffed(_ host: String) -> String {
        CdnRewrite.saveSniffed(host)
    }

    private static func appendUnique(_ list: inout [String], _ v: String) {
        if !list.contains(v) { list.append(v) }
    }

    /// collectImageHosts: 每个 IMG_RE 命中 → `//` 开头补 `https:` → fullImgs + hosts
    private static func collectImageHosts(_ html: String, _ hosts: inout [String],
                                          _ fullImgs: inout [String]) {
        for u0 in CdnRewrite.matchValue(IMG_RE, html) {
            let u = u0.hasPrefix("//") ? "https:" + u0 : u0
            fullImgs.append(u)
            appendUnique(&hosts, CdnRewrite.hostOnly(u))
        }
    }

    /// fetchHtml: 单次 ≤8s; !isSuccessful → ""; 正文截断 800_000 字符; 异常兜 ""
    private static func fetchHtml(_ url: String, cookie: String? = nil) async -> String {
        guard let req = ImagePipeline.makeRequest(url, timeout: 8, cookie: cookie) else { return "" }
        let session = ImagePipeline.shared.session(forURL: url, sniff: true)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return ""
            }
            let s = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            return String(s.prefix(800_000))
        } catch {
            return ""
        }
    }

    /// probeImage: GET 成功后读满 16 字节头验魔数（★ NA-09: 手写循环读头语义;
    /// iOS 用 AsyncBytes 读到 16 字节即断开连接, 等价于 Android 手写 read 循环）
    private static func probeImage(_ url: String) async -> Bool {
        guard let req = ImagePipeline.makeRequest(url, timeout: 8) else { return false }
        let session = ImagePipeline.shared.session(forURL: url, sniff: true)
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            var head = Data()
            head.reserveCapacity(16)
            for try await b in bytes {
                head.append(b)
                if head.count >= 16 { break }
            }
            return CdnRewrite.isImageMagic(head)
        } catch {
            // Android: Log.w("probeImage failed: $e") → false
            return false
        }
    }

    /// 库内 thread_images 前 5 条 http URL 经 imgPathOf 归一
    /// （SQL = probe.shtimg, 已登记 SqlPolicy; 异常兜空）
    private static func testImageUrls() async -> [String] {
        do {
            let ti = await Db.tableOf("sht", "thread_images")
            let rows = try await Db.query(
                "sht", "SELECT url FROM \(ti) WHERE url LIKE 'http%' LIMIT 5")
            return rows.compactMap { CdnRewrite.imgPathOf($0.s("url")) }
        } catch {
            return []
        }
    }
}
