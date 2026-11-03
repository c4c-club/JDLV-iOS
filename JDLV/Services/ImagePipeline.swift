import UIKit
import CryptoKit
import JDLVCore

/// 图片加载协议（P7 图片管线入口; kind 决定桶与头）
protocol ImageLoading {
    func image(url: String, kind: CdnKind, half: Int) async -> UIImage?
}

/// 拉取失败（对齐 Android 拦截器链的失败分支: shell(code,msg) / IOException）
struct FetchFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/**
 * 图片管线（对齐 Android CdnRewrite.client 拦截器链 + Coil 磁盘缓存）:
 *  ① 直连失败自动代理回退（ProxyFallbackInterceptor 语义: IOException / 403+5xx
 *     → 代理重试一次; 成功后 10 分钟"优先代理"窗口; 代理也不通 → 2 分钟静音,
 *     仅图片加载 respectMute=true, 嗅探不静音）;
 *  ② 每个请求注入 DESKTOP_UA + refererFor(url)（UA+Referer 拦截器）;
 *  ③ jdb 图床: deobfuscateAuto + isImageMagic + 备用图床重试（DecodeVerifyInterceptor
 *     语义; 回退/早退路径的响应同样过解码/魔数验证 —— ★ S10-P0b 头像 31 连挂根因）;
 *  98t 图床: CdnRewrite.rewrite() 用嗅探到的 shtHost 做 withHost 替换（仅换 host）。
 *
 * 缓存: 内存 NSCache（≤100MB）+ 磁盘 LRU（Caches/jdlv_img/, imageCacheMb 默认
 * 128MB / imageCacheDays 默认 30 天, 0=不过期）; 同 URL 去重（in-flight Task 复用）;
 * 滚动取消 cancel(for:)。
 *
 * ★ iOS 简化（已记录移植报告）:
 *  1. DoH 解析结果暂不接入 URLSession（自定义 SNI/证书校验需 session delegate,
 *     本期不做）—— 请求走系统 DNS; DoHResolver 已实现并导出 resolve(host)。
 *  2. 代理回退路径的 404/502: Android 早退路径直接 fallbackOrThrow 抛错（无备用
 *     图床重试）; iOS 统一返回响应由 404/410→备用图床重试路径处理（与直连路径一致）。
 *  3. Android 解码替换 body 后移除 Content-Length/ETag/Last-Modified/Content-Encoding
 *     四头 —— iOS 侧 URLSession 缓存整体禁用（urlCache=nil + reloadIgnoringLocalCacheData）,
 *     磁盘缓存只存解码后字节, 不存在 304 复用错版本/头不匹配问题。
 */
final class ImagePipeline: ImageLoading {
    static let shared = ImagePipeline()

    // MARK: - 缓存

    /// 内存 NSCache（≤100MB; cost = 位图字节）
    private let memCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    private let diskLock = NSLock()
    private var lastCleanupAt: Int64 = 0
    private static let CLEANUP_INTERVAL_MS: Int64 = 5 * 60_000

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("jdlv_img", isDirectory: true)
    }

    // MARK: - in-flight 去重

    private final class Inflight {
        let task: Task<Data, Error>
        var refs = 0
        var done = false
        init(task: Task<Data, Error>) {
            self.task = task
            Task { [weak self] in
                _ = try? await task.value
                self?.done = true
            }
        }
    }

    private let inflightLock = NSLock()
    private var inflight: [String: Inflight] = [:]

    // MARK: - URLSession 池（jdb/98t 各自代理开关; 关闭直连）

    private let sessionLock = NSLock()
    private var sessions: [String: URLSession] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cleanupDiskIfNeeded()
    }

    // MARK: - 入口（协议方法）

    /// 图片加载: kind 决定桶与头; half = coverHalf 模式（0 右半 / 1 左半 / 2 整张）。
    /// 冷却判定用**重写后的最终 URL**（Android Img.url 语义）。
    func image(url: String, kind: CdnKind, half: Int) async -> UIImage? {
        #if DEBUG
        if TestImages.enabled() { return TestImages.testImage(for: url) }
        #endif
        // guarded: 无效 URL 不发请求（绝不把裸 id 当 URL）
        guard let g = ImgBreaker.guarded(url) else { return nil }
        let u = CdnRewrite.rewrite(g)
        if u.isEmpty { return nil }
        if ImgBreaker.shared.isBucketCooling(kind.bucket) { return nil }
        if ImgBreaker.shared.isUrlCooling(u) { return nil }
        if let hit = memCache.object(forKey: u as NSString) {
            return applyHalf(hit, half)
        }
        if let data = diskRead(u) {
            if let img = UIImage(data: data) {
                memCache.setObject(img, forKey: u as NSString, cost: pixelCost(img))
                return applyHalf(img, half)
            }
            try? FileManager.default.removeItem(at: diskURL(u))   // 坏缓存清除
        }
        let entry = inflightEntry(u, kind: kind)
        defer { finishInflight(u, entry) }
        do {
            let data = try await entry.task.value
            guard let img = UIImage(data: data) else {
                ImgBreaker.shared.recordFailure(u, error: "ImageDataInvalid")
                return nil
            }
            ImgBreaker.shared.recordSuccess(u)
            return applyHalf(img, half)
        } catch is CancellationError {
            return nil
        } catch {
            // 取消不算失败（Android Coil 取消不进 onError）
            if Task.isCancelled { return nil }
            ImgBreaker.shared.recordFailure(u, error: String(describing: type(of: error)))
            return nil
        }
    }

    /// 滚动取消: 取消该 URL 的在飞加载（同 URL 多等待方共享同一 Task, 取消波及
    /// 全部等待方 —— 简化点, 已记录移植报告）
    func cancel(for url: String) {
        guard let g = ImgBreaker.guarded(url) else { return }
        let key = CdnRewrite.rewrite(g)
        inflightLock.lock()
        let e = inflight.removeValue(forKey: key)
        inflightLock.unlock()
        e?.task.cancel()
    }

    // MARK: - in-flight

    private func inflightEntry(_ key: String, kind: CdnKind) -> Inflight {
        inflightLock.lock()
        if let e = inflight[key] {
            e.refs += 1
            inflightLock.unlock()
            return e
        }
        let e = Inflight(task: Task<Data, Error> { [weak self] in
            guard let self else { throw FetchFailure("pipeline deallocated") }
            return try await self.loadNetwork(key, kind)
        })
        inflight[key] = e
        inflightLock.unlock()
        return e
    }

    private func finishInflight(_ key: String, _ entry: Inflight) {
        inflightLock.lock()
        entry.refs -= 1
        if let cur = inflight[key], cur === entry, entry.done {
            inflight.removeValue(forKey: key)
        }
        inflightLock.unlock()
    }

    // MARK: - 网络层（含解码/验证/备用图床）

    /// in-flight 任务体: 拉取 + (jdb) 解码/魔数验证/备用图床重试; 成功即写两级缓存
    private func loadNetwork(_ u: String, _ kind: CdnKind) async throws -> Data {
        // 解码归属按单一分类判定（★ S12-P2 硬规则: 解码看字节不看域名 + kindOf 判定;
        // SHT/EXTERNAL 绝不解码、绝不重写）
        if CdnRewrite.isJdbImgUrl(u) {
            let data = try await verifiedJdbFetch(u, kind)
            cacheWrite(u, data)
            return data
        }
        let (data, code) = try await fetchRaw(url: u, kind: kind)
        guard (200..<300).contains(code) else { throw FetchFailure("HTTP \(code)") }
        cacheWrite(u, data)
        return data
    }

    /// jdb 图片: 404/410 → 备用图床; 解码/魔数不过 → 备用图床重试一次
    /// （Android DecodeVerifyInterceptor + verifyJdb 语义, altMark 打点逐字）
    private func verifiedJdbFetch(_ u: String, _ kind: CdnKind) async throws -> Data {
        let (data, code) = try await fetchRaw(url: u, kind: kind)
        if code == 404 || code == 410 {
            guard let altUrl = CdnRewrite.altJdbImgUrl(u) else {
                altMark(false, "alt unreachable (code=\(code))", url: u)
                throw FetchFailure("alt unreachable (code=\(code))")
            }
            if let (d, _) = try? await fetchRaw(url: altUrl, kind: kind),
               let dec = verifiedData(d) {
                altMark(true, "code=\(code)", url: u)
                return dec
            }
            altMark(false, "alt unreachable (code=\(code))", url: u)
            throw FetchFailure("alt unreachable (code=\(code))")
        }
        let dec = CdnRewrite.deobfuscateAuto(data)
        if CdnRewrite.isImageMagic(dec) { return dec }
        // 解码/验证失败 → 备用图床重试一次（独立新请求, 重试结果同样过校验）
        guard let altUrl = CdnRewrite.altJdbImgUrl(u) else {
            altMark(false, "no alt cdn", url: u)
            throw FetchFailure("no alt cdn (code=\(code))")
        }
        if let (d, _) = try? await fetchRaw(url: altUrl, kind: kind),
           let dec2 = verifiedData(d) {
            altMark(true, "decode fail", url: u)
            return dec2
        }
        altMark(false, "alt verify failed", url: u)
        throw FetchFailure("alt verify failed")
    }

    /// 读 body → 自适应解码 → 魔数验证; 不过关返回 nil（Android verified()）
    private func verifiedData(_ data: Data) -> Data? {
        let dec = CdnRewrite.deobfuscateAuto(data)
        return CdnRewrite.isImageMagic(dec) ? dec : nil
    }

    /// 备用图床打点: 区分"主图床 404/解码失败但备用成功"与"彻底失败"（★ S12-P2, 载荷逐字）
    private func altMark(_ ok: Bool, _ why: String, url: String) {
        let altKind = url.lowercased().contains("spfcas") ? "web" : "app"
        Perf.mark("img.err",
                  "alt=\(altKind) ok=\(ok ? 1 : 0) why=\(why) url=\(String(url.prefix(60)))")
    }

    // MARK: - 直连失败自动代理回退（ProxyFallbackInterceptor 语义）

    private enum AttemptResult {
        case response(Data, Int)
        case transport(String)
    }

    /// 单次尝试（transport 错误折叠为 .transport, 取消原样上抛）
    private func attempt(_ url: String, kind: CdnKind, proxied: Bool,
                         timeout: TimeInterval = 12) async throws -> AttemptResult {
        guard let req = Self.makeRequest(url, timeout: timeout) else {
            return .transport("bad url")
        }
        let session = self.session(forKind: kind, proxied: proxied)
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return .response(data, code)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let name = String(describing: type(of: error))
            return .transport("\(name): \(error.localizedDescription.prefix(80))")
        }
    }

    /**
     * 带代理回退的原始拉取（不解码）:
     * ① 代理窗口早退: now < preferProxyUntil 且 wantProxy(url) → 直接走代理
     *    （★ S11-P7: 早退路径同样按图床开关取用 —— 对应开关已关 → 不走代理, 落直连）;
     * ② 直连: 403/5xx → 关闭并回退; 回退不通 → 空体响应形态返回（绝不二次 proceed）;
     * ③ 直连传输失败 → 回退一次; 无代理或代理也不通 → 原样抛出（不吞）。
     */
    func fetchRaw(url: String, kind: CdnKind, respectMute: Bool = true) async throws -> (Data, Int) {
        // ① 代理窗口早退
        if Perf.nowMs() < CdnRewrite.preferProxyUntil, CdnRewrite.wantProxy(url) {
            if case .response(let data, let code) = try await attempt(url, kind: kind, proxied: true) {
                return (data, code)
            }
            // 早退代理失败 → 落直连
        }
        // ② 直连
        switch try await attempt(url, kind: kind, proxied: false) {
        case .response(let data, let code):
            if code == 403 || code >= 500 {
                if let fb = try await fallback(url: url, kind: kind, respectMute: respectMute) {
                    return fb
                }
                // 空体响应形态返回（对齐 Android: resp.newBuilder().body(空体).build()）
                return (Data(), code)
            }
            return (data, code)
        case .transport(let msg):
            // ③ 直连网络层失败 → 代理回退; 无代理或代理也不通 → 原样抛出
            if let fb = try await fallback(url: url, kind: kind, respectMute: respectMute) {
                return fb
            }
            throw FetchFailure(msg)
        }
    }

    /// 代理回退一次（Android ProxyFallbackInterceptor.fallback）:
    /// - 开关关闭 → 直接不做代理回退;
    /// - respectMute 且静音期内 → null（图片加载静音; 嗅探 respectMute=false 每次都尽力）;
    /// - 成功 → preferProxyUntil = now + 10 分钟; 404/502 或失败 → 静音 2 分钟。
    private func fallback(url: String, kind: CdnKind, respectMute: Bool) async throws -> (Data, Int)? {
        guard CdnRewrite.wantProxy(url) else { return nil }
        if respectMute && Perf.nowMs() < CdnRewrite.fallbackBlockedUntil { return nil }
        if case .response(let data, let code) = try await attempt(url, kind: kind, proxied: true, timeout: 10) {
            if (200..<300).contains(code) {
                CdnRewrite.preferProxyUntil = Perf.nowMs() + 10 * 60_000
                return (data, code)
            }
        }
        CdnRewrite.fallbackBlockedUntil = Perf.nowMs() + 2 * 60_000
        return nil
    }

    // MARK: - 请求构造（UA + Referer 拦截器语义）

    /// 每个请求注入 DESKTOP_UA + refererFor(url)（值逐字; cookie 供嗅探 _safe 流程）
    static func makeRequest(_ url: String, timeout: TimeInterval = 12,
                            cookie: String? = nil) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue(CdnRewrite.DESKTOP_UA, forHTTPHeaderField: "User-Agent")
        req.setValue(CdnRewrite.refererFor(url), forHTTPHeaderField: "Referer")
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return req
    }

    // MARK: - URLSession 池

    /// 按 URL 取会话（嗅探用; 8s 单次调用超时对齐 Android sniffClient callTimeout）
    func session(forURL url: String, sniff: Bool = false) -> URLSession {
        let kind = CdnRewrite.kindOf(url)
        let proxied = CdnRewrite.wantProxy(url)
        return session(forKind: kind, proxied: proxied, sniff: sniff)
    }

    /// 会话按 (图床组, 是否代理, 是否嗅探) 缓存; 代理开关注入
    /// connectionProxyDictionary（jdb → proxyCdnJdb / sht → proxyCdnSht, 关闭直连;
    /// 设置热生效经 CdnRewrite.invalidate() → evictSessions 重建）。
    /// 超时对齐 Android 主 client: connect 12s / read 30s。
    func session(forKind kind: CdnKind, proxied: Bool, sniff: Bool = false) -> URLSession {
        let group = kind.isJdb ? "jdb" : (kind == .sht ? "sht" : "ext")
        let key = "\(group)|\(proxied ? 1 : 0)|\(sniff ? 1 : 0)"
        sessionLock.lock()
        if let s = sessions[key] {
            sessionLock.unlock()
            return s
        }
        sessionLock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil                       // 自管磁盘缓存; 杜绝 304 复用错版本
        cfg.timeoutIntervalForRequest = sniff ? 8 : 12
        cfg.timeoutIntervalForResource = 30
        if proxied, let pa = CdnRewrite.proxyAddr() {
            // CFNetwork 代理键的字符串字面量（iOS 未导出 HTTPS 常量, 用原始键名）
            cfg.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": pa.host,
                "HTTPPort": pa.port,
                "HTTPSEnable": 1,
                "HTTPSProxy": pa.host,
                "HTTPSPort": pa.port,
            ]
        }
        let s = URLSession(configuration: cfg)
        sessionLock.lock()
        if let existing = sessions[key] {        // 双检（并发创建时复用先到者）
            sessionLock.unlock()
            s.invalidateAndCancel()
            return existing
        }
        sessions[key] = s
        sessionLock.unlock()
        return s
    }

    /// 旧代理连接全部作废（Android connectionPool.evictAll 对位; iOS 无 evictAll,
    /// 按"当前任务继续完成 + 新请求走新会话"处理）
    func evictSessions() {
        sessionLock.lock()
        let old = Array(sessions.values)
        sessions.removeAll()
        sessionLock.unlock()
        for s in old { s.finishTasksAndInvalidate() }
    }

    // MARK: - 缓存读写

    private func cacheWrite(_ u: String, _ data: Data) {
        guard let img = UIImage(data: data) else { return }
        memCache.setObject(img, forKey: u as NSString, cost: pixelCost(img))
        diskWrite(u, data)
    }

    private func pixelCost(_ img: UIImage) -> Int {
        guard let cg = img.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    private func diskURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent(sha256Hex(key))
    }

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func diskRead(_ key: String) -> Data? {
        let url = diskURL(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date else { return nil }
        // imageCacheDays: 按文件时间过期; 0 = 不过期（Android 注释逐字）
        let days = CdnRewrite.settings().imageCacheDays
        if days > 0 && Date().timeIntervalSince(mod) > Double(days) * 86400 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private func diskWrite(_ key: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: diskURL(key), options: .atomic)
        cleanupDiskIfNeeded()
    }

    /// LRU/过期清理: imageCacheMb 超限按修改时间最旧先删; imageCacheDays 过期删除
    /// （0 = 不过期）。每次写入至多触发一次（5 分钟节流）。
    private func cleanupDiskIfNeeded() {
        diskLock.lock()
        let now = Perf.nowMs()
        if now - lastCleanupAt < Self.CLEANUP_INTERVAL_MS {
            diskLock.unlock()
            return
        }
        lastCleanupAt = now
        diskLock.unlock()
        let dir = cacheDir
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return }
            var items: [(url: URL, size: Int, mod: Date)] = []
            for f in files {
                guard let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                else { continue }
                items.append((f, vals.fileSize ?? 0, vals.contentModificationDate ?? Date()))
            }
            let days = CdnRewrite.settings().imageCacheDays
            if days > 0 {
                let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
                for it in items where it.mod < cutoff {
                    try? FileManager.default.removeItem(at: it.url)
                }
                items.removeAll { $0.mod < cutoff }
            }
            let mb = CdnRewrite.settings().imageCacheMb
            guard mb > 0 else { return }   // 0 = 不限
            let limit = Int64(mb) * 1024 * 1024
            var total = items.reduce(Int64(0)) { $0 + Int64($1.size) }
            guard total > limit else { return }
            for it in items.sorted(by: { $0.mod < $1.mod }) {   // LRU: 最旧先删
                try? FileManager.default.removeItem(at: it.url)
                total -= Int64(it.size)
                if total <= limit { break }
            }
        }
    }

    // MARK: - 半图裁切（CoverHalf 消费）

    /// mode: 0 右半 / 1 左半 / 2 整张; 条件/异常回原图（Android CoverHalf.transform 语义）
    private func applyHalf(_ img: UIImage, _ half: Int) -> UIImage {
        guard let cg = img.cgImage,
              let rect = CoverHalf.cropRect(cw: cg.width, ch: cg.height, mode: half),
              let cut = cg.cropping(to: rect) else { return img }
        return UIImage(cgImage: cut, scale: img.scale, orientation: img.imageOrientation)
    }
}
