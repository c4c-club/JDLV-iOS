import Foundation
import JDLVCore

// 网络出口与图床（对齐 Android data/CdnRewrite.kt, 700 行）:
// 1. 代理可选 (图片 CDN HTTP 按 jdb / 98t 图床各自开关), 直连失败自动代理回退;
// 2. DoH (阿里): 图床域名防污染解析, 失败回退系统 DNS (见 DoHResolver);
// 3. 防盗链 Referer: jdb 网页图床认 javdb 主站, 98t 图床认论坛主站;
// 4. jdb 图床三选 (设置页手动选择):
//      app  = tp.spfcas.com/rhe951l4q/... (默认, 风控最宽松)
//      web  = c0.jdbstatic.com/...       (备用)
//      其他 = 自定义镜像 URL (spfcas 系镜像自动补 /rhe951l4q 前缀)
//    app 图床返回毒丸: 响应 = [d] + 原图逐字节 XOR d (d 即响应首字节),
//    管线自动解码 + 魔数验证 (解码看字节不看域名), 验证不过自动切备用图床重试。

/// 设置快照（字段名 = Android AppSettings 同名字段, docs/_extract/13 §B）。
/// P6 SettingsStore 落地后由 App 层注入:
///   CdnRewrite.settingsProvider = { SettingsStore.shared.snapshot() }
public struct CdnSettings: Sendable {
    public var jdbImgHost: String        // "app" / "web" / 自定义镜像 URL（默认 "app"）
    public var shtMirror: String         // 98t 论坛主站地址（嗅探）
    public var shtMirrorHost: String     // 嗅探结果持久化 host
    public var proxyHost: String
    public var proxyPort: String         // 默认 "7890"
    public var proxyCdnJdb: Bool         // 图床代理分离 (S11-P7): jdb 图床
    public var proxyCdnSht: Bool         // 98t 图床
    public var imageCacheMb: Int         // 默认 128 (S6: 旧 256→128)
    public var imageCacheDays: Int       // 按文件时间过期; 0=不过期 (默认 30)
    public var coverHalf: Int            // 0=右半 1=左半 2=整张 (默认 0)
    public var testImgMode: Bool         // 测试图片模式 (默认 false)
    public var allowInsecureHTTP: Bool   // R4 S1：明文 HTTP 镜像显式开关 (默认 false)

    public init(
        jdbImgHost: String = "app",
        shtMirror: String = "",
        shtMirrorHost: String = "",
        proxyHost: String = "",
        proxyPort: String = "7890",
        proxyCdnJdb: Bool = false,
        proxyCdnSht: Bool = false,
        imageCacheMb: Int = 128,
        imageCacheDays: Int = 30,
        coverHalf: Int = 0,
        testImgMode: Bool = false,
        allowInsecureHTTP: Bool = false
    ) {
        self.jdbImgHost = jdbImgHost
        self.shtMirror = shtMirror
        self.shtMirrorHost = shtMirrorHost
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyCdnJdb = proxyCdnJdb
        self.proxyCdnSht = proxyCdnSht
        self.imageCacheMb = imageCacheMb
        self.imageCacheDays = imageCacheDays
        self.coverHalf = coverHalf
        self.testImgMode = testImgMode
        self.allowInsecureHTTP = allowInsecureHTTP
    }
}

/// 图床**单一分类**（对齐 Android CdnRewrite.CdnKind; ★ S12-P2 硬规则 1:
/// 代理开关 / 重写 / 解码 / Referer / 熔断分桶全部只读这一个结果）。
public enum CdnKind: CaseIterable, Sendable {
    /// JDB_APP → 桶 "app" (tp.spfcas.com / 相对路径 / 空)
    case jdbApp
    /// JDB_WEB → 桶 "web" (c0.jdbstatic.com)
    case jdbWeb
    /// JDB_OTHER → 桶 "other" (自定义镜像 / javdb 主站镜像 + 白名单路径)
    case jdbOther
    /// SHT → 桶 "sht" (98t 图床)
    case sht
    /// EXTERNAL → 桶 "ext" (instagram/x.com 等外链: 不重写/不解码, 熔断弱化)
    case external

    /// 熔断桶名（Img.bucketOf 逐字: "app"/"web"/"other"/"sht"/"ext"）
    public var bucket: String {
        switch self {
        case .jdbApp: return "app"
        case .jdbWeb: return "web"
        case .jdbOther: return "other"
        case .sht: return "sht"
        case .external: return "ext"
        }
    }

    /// jdb 图床判定: 非 SHT/EXTERNAL 即 true（isJdbImage, 代理开关归属）
    public var isJdb: Bool { self != .sht && self != .external }
}

public enum CdnRewrite {
    // MARK: - 常量（逐字）

    public static let APP_CDN = "https://tp.spfcas.com"
    public static let WEB_CDN = "https://c0.jdbstatic.com"
    /// app 图床路径前缀（硬编码在 jdbImgUrl/altJdbImgUrl 里, 非独立常量的形态按此保留）
    static let APP_CDN_PREFIX = "/rhe951l4q"
    public static let DESKTOP_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"
    /// Referer 判定用（jdb 图床 host 特征）
    static let JDB_IMG_HOSTS = ["jdbstatic", "jdforrepam", "spfcas", "javdb.com"]
    /// ★ S12-P2: 已知 98t 论坛图床 host 特征（可扩; 库内 sht_img_hosts.state=dead
    /// 的 tumblr/33img/wk920 等也属此类, 死域不计入 jdb 熔断）
    static let SHT_IMG_HOSTS = [
        "imgbox", "tumblr", "shttupian", "shtfly", "sehuatang", "wk920", "33img"]
    static let JDB_REFERER = "https://javdb580.com/"
    static let SHT_REFERER_FALLBACK = "https://www.sehuatang.org/"
    static let DEFAULT_PROXY_PORT = 7890

    /// 路径白名单。★ alternation 顺序敏感: `articles/images` 必须排在 `articles`
    /// 之前（正则按序取第一命中）; kind 一律取 group 1（含 "articles/images" 整体）。
    /// ★ S12-P2 扩 articles: articles.content_html 正文主图 host 是 c0, 不进白名单
    /// 则既不换图床也不解码。
    static let IMG_PATH_RE = try! NSRegularExpression(
        pattern: "/(covers|small_covers|samples|avatars|articles/images|articles)/")

    /// rewrite 的 98t host 替换用扩展名判定
    static let IMG_EXT_RE = try! NSRegularExpression(
        pattern: "\\.(jpe?g|png|webp|gif|avif)(\\?|$)", options: [.caseInsensitive])

    /// withHost 用（只换 host, 路径原样）
    static let WITH_HOST_RE = try! NSRegularExpression(pattern: "^(https?)://[^/]+(/.*)?$")

    /// LRU 512（rewrite 幂等集合上限）
    static let REWRITTEN_MAX = 512

    // MARK: - 设置注入（P6 SettingsStore 落地前用默认值兜底）

    /// 设置提供器（App 层注入; 默认全默认值。Android 侧对应 Db.prefs.current
    /// 的 try/catch 兜底读取）
    public static var settingsProvider: () -> CdnSettings = { CdnSettings() }

    static func settings() -> CdnSettings { settingsProvider() }

    // MARK: - Kotlin 助手对位

    /// Kotlin substringAfter（缺分隔符 → 整串; missing 覆盖时 → missing）
    static func substringAfter(_ s: String, _ sep: String, missing: String? = nil) -> String {
        if let r = s.range(of: sep) { return String(s[r.upperBound...]) }
        return missing ?? s
    }

    /// Kotlin substringBefore（缺分隔符 → 整串; missing 覆盖时 → missing）
    static func substringBefore(_ s: String, _ sep: String, missing: String? = nil) -> String {
        if let r = s.range(of: sep) { return String(s[..<r.lowerBound]) }
        return missing ?? s
    }

    /// Kotlin String.isBlank
    static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Kotlin trimEnd('/')
    static func trimEndSlash(_ s: String) -> String {
        var t = s
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// hostOnly(u) = u.substringAfter("://").substringBefore('/')
    public static func hostOnly(_ u: String) -> String {
        substringBefore(substringAfter(u, "://"), "/")
    }

    // MARK: - 单一分类 kindOf

    /**
     * 图床单一分类（判定顺序不可乱, 全部小写比较）:
     *  1) 空串 / 相对路径 (不含 "://") → jdbApp (保持旧行为, 调用方守卫)
     *  2) host 含 "spfcas" → jdbApp
     *  3) host 含 "jdbstatic" → jdbWeb
     *  4) 仅当 jdbImgHost 是 http(s) 开头 (用户填了自定义镜像) 时取其 host,
     *     当前 host 等于/包含它 → jdbOther
     *     ★ 必须先判 http 前缀: 默认值 "app"/"web" 取 host 会得到空串, 空串
     *       contains 恒 true → 所有 URL 都会被误判成 JDB_OTHER (灾难性误判)
     *  5) 路径命中 IMG_PATH_RE 且 host 是 javdb 相关 (javdb/jdforrepam) → jdbOther
     *  6) host 命中 98t 图床集合 (含 shtMirrorHost / shtMirror 的 host) → sht
     *  7) 其它 → external (不重写/不解码/不代理, 熔断走弱化的 ext 桶)
     */
    public static func kindOf(_ raw: String) -> CdnKind {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || !s.contains("://") { return .jdbApp }
        let low = s.lowercased()
        let host = hostOnly(s).lowercased()
        if host.contains("spfcas") { return .jdbApp }
        if host.contains("jdbstatic") { return .jdbWeb }
        // 4) 用户自定义镜像（必须先判 http(s) 前缀, 见上方 ★ 注释）
        let mirror = settings().jdbImgHost
        if mirror.hasPrefix("http://") || mirror.hasPrefix("https://") {
            let mh = hostOnly(mirror).lowercased()
            if !mh.isEmpty && (host == mh || host.contains(mh)) { return .jdbOther }
        }
        // 5) javdb 主站/镜像 + 白名单路径
        if firstMatch(IMG_PATH_RE, low) != nil
            && (host.contains("javdb") || host.contains("jdforrepam")) {
            return .jdbOther
        }
        // 6) 98t 论坛图床 (已知集合 + 嗅探/手填的镜像 host)
        if SHT_IMG_HOSTS.contains(where: { host.contains($0) }) { return .sht }
        let smh = settings().shtMirrorHost
        if !isBlank(smh) && host.contains(smh.lowercased()) { return .sht }
        let sm = settings().shtMirror
        if sm.hasPrefix("http") {
            let h = hostOnly(sm).lowercased()
            if !h.isEmpty && host.contains(h) { return .sht }
        }
        return .external
    }

    /// jdb 图片请求?（★ S12-P2: kindOf 判定 —— 自定义镜像与 articles 路径的
    /// 响应也走解码/验证; SHT/EXTERNAL 不解码）
    public static func isJdbImgUrl(_ url: String) -> Bool {
        switch kindOf(url) {
        case .jdbApp, .jdbWeb, .jdbOther: return true
        default: return false
        }
    }

    /// 代理开关归属判定（isJdbImage: kindOf 非 SHT/EXTERNAL 即 true）
    public static func isJdbImage(_ url: String) -> Bool { kindOf(url).isJdb }

    // MARK: - 路径白名单

    /// 归一图片路径 /covers|small_covers|samples|avatars|articles/images|articles/xx/id.ext
    /// （裸 id 生成封面路径; ★ S12-P2: kind 直接取正则 group 1, 含 "articles/images"）
    public static func imgPathOf(_ urlOrId: String) -> String? {
        guard let m = firstMatch(IMG_PATH_RE, urlOrId),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound,
              let kindRange = Range(m.range(at: 1), in: urlOrId) else { return nil }
        let kind = String(urlOrId[kindRange])
        let tail = substringBefore(substringAfter(urlOrId, "\(kind)/", missing: ""), "?")
        return tail.isEmpty ? nil : "/\(kind)/\(tail)"
    }

    // MARK: - jdb 图床三选重建 / 备用

    /// jdb 图片 URL 按用户图床设置重建 (app=spfcas+前缀 / web=c0 / 其他=自定义镜像)。
    /// ★ S12-P2: 先过 kindOf —— SHT/EXTERNAL 一律原样返回, 绝不重写;
    /// 路径不认识 (imgPathOf nil) → 原样返回, 绝不拼 null。
    /// 这样: c0 的 articles 图 → 重写到 spfcas (实测 200); spfcas 的 articles 图 → 幂等不变。
    public static func jdbImgUrl(_ urlOrId: String) -> String {
        guard let path = imgPathOf(urlOrId) else { return urlOrId }
        switch kindOf(urlOrId) {
        case .sht, .external: return urlOrId
        default: break
        }
        let s = settings().jdbImgHost
        if s == "web" { return WEB_CDN + path }
        if isBlank(s) || s == "app" { return APP_CDN + APP_CDN_PREFIX + path }
        // 自定义镜像（spfcas 系自动补前缀）
        let base = trimEndSlash(s)
        let pref = base.contains("spfcas") ? APP_CDN_PREFIX : ""
        return base + pref + path
    }

    /// 主图床的备用: app↔web 互换 (自定义 → web)
    public static func altJdbImgUrl(_ url: String) -> String? {
        guard let path = imgPathOf(url) else { return nil }
        let host = hostOnly(url)
        if host.contains("spfcas") { return WEB_CDN + path }
        if host.contains("jdbstatic") { return APP_CDN + APP_CDN_PREFIX + path }
        return WEB_CDN + path
    }

    // MARK: - 毒丸解码 / 魔数（逐字字节序列）

    /**
     * ★ S12-P2 (P2.3) 响应自适应解码 —— 解码看字节不看域名 (硬规则 2):
     *  1) 原始首 4 字节已是图片魔数 → 明文, 原样返回;
     *  2) 否则按毒丸 [d] + 逐字节 XOR d 解码 (解码后长度少 1 字节), 解出魔数 → 返回解码结果;
     *  3) 两者都不中 → 原样交回 (交给上层报错, 不吞)。
     * 对 app 图床 / 自定义镜像 / articles 路径一律适用 (配合 kindOf 判定);
     * SHT/EXTERNAL 不解码。
     */
    public static func deobfuscateAuto(_ data: Data) -> Data {
        if data.count < 4 { return data }
        if isImageMagic(data) { return data }                    // 明文
        let bytes = [UInt8](data)
        let d = bytes[0]
        var dec = [UInt8](repeating: 0, count: bytes.count - 1)
        for i in 0..<dec.count { dec[i] = bytes[i + 1] ^ d }
        let decData = Data(dec)
        return isImageMagic(decData) ? decData : data            // 不明格式原样交回
    }

    /// JDB 图片毒丸解码（兼容入口, ★ S12-P2 起内部委托 deobfuscateAuto）
    public static func deobfuscate(_ data: Data) -> Data { deobfuscateAuto(data) }

    /// 魔数判定（4 种, 逐字; ★ NA-21: WebP 必须按完整魔数长度 12 判断,
    /// JPEG/PNG/GIF 只查前 2 字节）
    public static func isImageMagic(_ b: Data) -> Bool {
        if b.count < 4 { return false }
        let head = [UInt8](b.prefix(12))   // 最多看 12 字节
        let b0 = head[0], b1 = head[1]
        if b0 == 0xFF && b1 == 0xD8 { return true }              // JPEG
        if b0 == 0x89 && b1 == 0x50 { return true }              // PNG
        if b0 == 0x47 && b1 == 0x49 { return true }              // GIF ('G''I', 兼容 87a/89a)
        // WebP (RIFF): "RIFF????WEBP" 的 R/I + 偏移 8/9 的 W/E
        if head.count >= 12 && b0 == 0x52 && b1 == 0x49
            && head[8] == 0x57 && head[9] == 0x45 { return true }
        return false
    }

    // MARK: - Referer / UA（防盗链, 逐字）

    /// refererFor: jdb 网页图床认 javdb 主站, 98t 图床认论坛主站
    /// （移植桌面端 server._img_referer; shtMirror 空则兜 sehuatang 主站, 确保尾随 /）
    public static func refererFor(_ url: String) -> String {
        let low = url.lowercased()
        if JDB_IMG_HOSTS.contains(where: { low.contains($0) }) {
            return JDB_REFERER
        }
        let sm = settings().shtMirror
        let base = isBlank(sm) ? SHT_REFERER_FALLBACK : sm
        return base.hasSuffix("/") ? base : base + "/"
    }

    // MARK: - 代理

    /// proxyAddr: proxyHost 非空白 → (host, port)，port 兜底 7890
    public static func proxyAddr() -> (host: String, port: Int)? {
        let s = settings()
        if isBlank(s.proxyHost) { return nil }
        return (s.proxyHost, Int(s.proxyPort) ?? DEFAULT_PROXY_PORT)
    }

    /// 当前 URL 应取哪个图床代理开关（★ S11-P7: 按图床类别取, 不是一刀切;
    /// jdb 图床 → proxyCdnJdb, 其余 (sht/ext) → proxyCdnSht; 且要求 proxyHost 非空）
    public static func wantProxy(_ url: String) -> Bool {
        let s = settings()
        let want = isJdbImage(url) ? s.proxyCdnJdb : s.proxyCdnSht
        return want && !isBlank(s.proxyHost)
    }

    // MARK: - 代理窗口（object 级状态, ★ P2.3: 提升到 object 级, invalidate 可触达）

    private static let windowLock = NSLock()
    private static var _preferProxyUntil: Int64 = 0
    private static var _fallbackBlockedUntil: Int64 = 0

    /// 10 分钟"优先代理"窗口截止（fallback 成功后设置）
    static var preferProxyUntil: Int64 {
        get { windowLock.lock(); defer { windowLock.unlock() }; return _preferProxyUntil }
        set { windowLock.lock(); _preferProxyUntil = newValue; windowLock.unlock() }
    }

    /// 2 分钟静音截止（代理也不通时; 仅图片加载 respectMute=true 生效）
    static var fallbackBlockedUntil: Int64 {
        get { windowLock.lock(); defer { windowLock.unlock() }; return _fallbackBlockedUntil }
        set { windowLock.lock(); _fallbackBlockedUntil = newValue; windowLock.unlock() }
    }

    // MARK: - 98t 嗅探结果（内存态）

    private static let shtStateLock = NSLock()
    private static var _shtHost: String?
    private static var _lastShtSite: String?

    /// 嗅探到的 98t 图床 host（可带可不带 scheme; withHost 兼容两者）
    public static var shtHost: String? {
        get { shtStateLock.lock(); defer { shtStateLock.unlock() }; return _shtHost }
        set { shtStateLock.lock(); _shtHost = newValue; shtStateLock.unlock() }
    }

    /// 上次嗅探使用的主站地址（进程内防重嗅）
    public static func lastSiteOf(_ kind: String) -> String? {
        guard kind == "sht" else { return nil }
        shtStateLock.lock(); defer { shtStateLock.unlock() }
        return _lastShtSite
    }

    /// 嗅探成功: 只更新内存 shtHost 并返回（★ S14-P1 数据层不写设置;
    /// sht_mirror_host 的持久化由调用方 ui 层走 SettingsStore 完成）
    static func saveSniffed(_ host: String) -> String {
        shtHost = host
        shtStateLock.lock(); _lastShtSite = host; shtStateLock.unlock()
        return host
    }

    /// 应用已保存设置（启动/设置变更）—— ★ S14-P1/P2 (docs/76 R1, B02):
    /// 本函数只做纯赋值（不联网）; 旧版在设置写锁内直接嗅探是 "改设置没反应" 的
    /// 直接根因。嗅探由 ui 层显式动作经 CdnSniffer 单飞 worker 完成。
    public static func applyHostOnly() {
        let h = settings().shtMirrorHost
        shtHost = isBlank(h) ? nil : h
    }

    // MARK: - rewrite / 归一化

    /// 已重写过的 URL 集合（access-order LRU 512, 保证 rewrite 幂等:
    /// 管线调用与手动调用双重进入不错乱）
    private static let rewrittenLock = NSLock()
    private static var rewrittenKeys: [String] = []
    private static var rewrittenSet = Set<String>()

    public static func rewrite(_ url: String) -> String {
        if isBlank(url) { return url }
        rewrittenLock.lock()
        let hit = rewrittenSet.contains(url)
        if hit {
            rewrittenKeys.removeAll { $0 == url }   // access-order touch
            rewrittenKeys.append(url)
        }
        rewrittenLock.unlock()
        if hit { return url }
        let out = rewriteOnce(url)
        if out != url {
            rewrittenLock.lock()
            if !rewrittenSet.contains(out) {
                rewrittenSet.insert(out)
                rewrittenKeys.append(out)
                while rewrittenKeys.count > REWRITTEN_MAX {
                    let eldest = rewrittenKeys.removeFirst()
                    rewrittenSet.remove(eldest)
                }
            }
            rewrittenLock.unlock()
        }
        return out
    }

    private static func rewriteOnce(_ url: String) -> String {
        // jdb 图片: 按用户图床设置重建 (app=spfcas / web=c0 / 自定义)
        if isAbsoluteHttpUrl(url) && isJdbImgUrl(url) { return jdbImgUrl(url) }
        // 98t 图床 host 替换（只换 host 不换路径）
        if let sh = shtHost, url.hasPrefix("http"), isImageExt(url), !url.contains("spfcas") {
            return withHost(url, sh)
        }
        return url
    }

    /// OkHttp toHttpUrl() 对位: 绝对 http(s) URL 才算解析成功
    static func isAbsoluteHttpUrl(_ url: String) -> Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && u.host != nil
    }

    static func isImageExt(_ u: String) -> Bool { firstMatch(IMG_EXT_RE, u) != nil }

    /// 只换 host, 路径原样; hostPart 可带可不带 scheme（缺省补 https）。
    /// Android 逐字: scheme = hostPart.substringBefore("://", missing="").ifEmpty { "https" }
    static func withHost(_ url: String, _ hostPart: String) -> String {
        guard let m = firstMatch(WITH_HOST_RE, url) else { return url }
        let path: String
        if m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound,
           let r = Range(m.range(at: 2), in: url) {
            path = String(url[r])
        } else {
            path = "/"
        }
        var scheme = substringBefore(hostPart, "://", missing: "")
        if scheme.isEmpty { scheme = "https" }
        let host = substringAfter(hostPart, "://")
        return "\(scheme)://\(host)\(path)"
    }

    /// 归一化: 无协议自动补 https:// (用户不必手输); trim + 去尾随 '/'
    /// R4 S1：默认补 https；用户输入的 http:// 仅在显式开启 allowInsecureHTTP 时保留，
    /// 否则强制改写为 https（明文镜像不再静默入库）。
    public static func normalizeUrl(_ u: String) -> String {
        let t = trimEndSlash(u.trimmingCharacters(in: .whitespacesAndNewlines))
        if t.isEmpty { return "" }
        if t.hasPrefix("https://") { return t }
        if t.hasPrefix("http://") {
            if settings().allowInsecureHTTP { return t }
            return "https://" + t.dropFirst("http://".count)
        }
        return "https://\(t)"
    }

    // MARK: - 热生效

    /**
     * 代理/图床设置热生效（Db.reset 与 rebuildImageLoader 在 MainVm.autoSave 里随之调用）:
     *  - rewritten 集合 (旧图床替换结果全部作废, 下次按新设置重建);
     *  - preferProxyUntil / fallbackBlockedUntil (代理窗口清零);
     *  - lastShtSite (允许对新主站重新嗅探);
     *  - URLSession 连接池 (旧代理连接全部作废; iOS 无 evictAll, 按会话重建)。
     */
    public static func invalidate() {
        rewrittenLock.lock()
        rewrittenKeys.removeAll()
        rewrittenSet.removeAll()
        rewrittenLock.unlock()
        preferProxyUntil = 0
        fallbackBlockedUntil = 0
        shtStateLock.lock(); _lastShtSite = nil; shtStateLock.unlock()
        ImagePipeline.shared.evictSessions()
        Perf.mark("cdn.invalidate")
    }

    // MARK: - 正则助手

    static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// 取正则 match 的 value（group 0）
    static func matchValue(_ re: NSRegularExpression, _ s: String) -> [String] {
        var out: [String] = []
        let ns = s as NSString
        re.enumerateMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            out.append(ns.substring(with: m.range(at: 0)))
        }
        return out
    }

    /// 取正则第一个 match 的捕获组
    static func group(_ re: NSRegularExpression, _ s: String, _ index: Int) -> String? {
        guard let m = firstMatch(re, s), m.numberOfRanges > index,
              m.range(at: index).location != NSNotFound,
              let r = Range(m.range(at: index), in: s) else { return nil }
        return String(s[r])
    }
}
