//
//  Settings.swift
//  JDLVCore
//
//  对齐 Android data/Prefs.kt 的 AppSettings 数据类（docs/_extract/13_theme_prefs_models.md §B）。
//  72 键 = String 30 + Int 24 + Boolean 18；另有 6 个派生 getter（host/port/user/pass/jdbDb/shtDb）
//  与 setupRequired，不落盘。
//
//  口径（B.5 逐条复刻）：
//  1. query_timeout 档位 {4,8,15,30}，档位外归一 8；
//  2. home_per 档位 {12,18,24,36}，档位外归一 24；
//  3. 上限哨兵 ≥ Int32.max/2 → 0（0 = 不限，LimitMath.normalizeStored）；
//  4. view_mode 未落盘时按旧 big 布尔换算（big=true→1，false→0；big 键保留不删）；
//  5. proxy_cdn_jdb / proxy_cdn_sht 未落盘时沿用旧 proxy_cdn；
//  6. rd_line_height / rd_paragraph 实际为 Float，落盘 ×10 的 Int（读 i(...)/10f）；
//  7. taxonomy_ts 落盘秒级 Int（写时 clamp [0, Int32.max]，上层读为 Int64）。
//
//  存储简化（iOS 侧刻意差异，见任务 P6）：Android DataStore 每键一条 → iOS 用
//  JSONSerialization 把 toStorage() 的 [String: Any] 编码为单个 UserDefaults 键
//  `jdlv_settings_v1`（JSONRepresentation）。口令键（remote_pass/local_pass/lock_secret）
//  由 Store 落盘前剔除、走 Keychain；Core 只提供剔除后的存储视图。
//
//  纯 Foundation（禁 UIKit 等其它框架），Linux 可跑单测。
//

import Foundation

public struct AppSettings: Equatable {

    // MARK: - String 键（30，KS 表；键名与字段名一一对应）

    public var dbSrc: String = "remote"          // 数据源：local / remote
    public var localHost: String = "127.0.0.1"
    public var localPort: String = "3306"
    public var localUser: String = ""            // A-18：旧版预填 root，改空
    public var localPass: String = ""            // 口令：Store 层走 Keychain
    public var localJdb: String = "javdb"
    public var localSht: String = "sehuatang"
    public var remoteHost: String = ""           // R4：默认空，用户在设置里填写；不预置任何内网地址
    public var remotePort: String = "3306"       // A-26/R4：通用默认 3306
    public var remoteUser: String = ""
    public var remotePass: String = ""           // 口令：Store 层走 Keychain
    public var remoteJdb: String = "javdb"
    public var remoteSht: String = "sehuatang"
    public var themeName: String = "dark"        // dark / light / sepia / system
    public var themeAccent: String = "紫"         // 未命中 ACCENTS → 紫
    public var jdbSort: String = "release_date"
    public var actorSort: String = "videos"
    public var actorGender: String = "f"
    public var rdFontFamily: String = ""         // 阅读器字体（空=默认）
    public var rdBgColor: String = ""            // 阅读器背景色（空=默认）
    public var rdFgColor: String = ""            // 阅读器前景色（空=默认）
    public var rdAltA: String = ""               // 阅读器替换色 A
    public var rdAltB: String = "#9aa0ad"        // 阅读器替换色 B
    public var proxyHost: String = ""
    public var proxyPort: String = "7890"
    public var jdbImgHost: String = "app"        // app / web / 自定义镜像 URL
    public var shtMirror: String = ""            // 98t 论坛主站地址（嗅探）
    public var shtMirrorHost: String = ""
    public var lockType: String = "none"         // none / pin / pattern / biometric
    public var lockSecret: String = ""           // 哈希后的凭据：Store 层走 Keychain

    // MARK: - Int 键（24，KI 表）

    public var perPage: Int = 40
    public var shtPer: Int = 20
    public var rdFontPt: Int = 16
    /// 阅读器行高（Float 2.0；落盘 ×10 存 Int 20）
    public var rdLineHeight: Float = 2.0
    /// 阅读器段距（Float 1.0；落盘 ×10 存 Int 10）
    public var rdParagraph: Float = 1.0
    public var homeTtl: Int = 10                 // 首页缓存 TTL（分钟）
    public var catTtl: Int = 10
    public var filterTtl: Int = 60
    public var imageCacheMb: Int = 128           // S6：旧 256 → 128MB
    public var imageCacheDays: Int = 30          // 0 = 不过期
    public var semCand: Int = 3000               // A-21：旧硬编码 10000
    public var connectTimeout: Int = 8           // A-23：旧死字段已接进持久化；A10/R9：默认对齐 UI 档位 {4,8,15,30}
    public var queryTimeout: Int = 8             // S1：档位 {4,8,15,30}，档位外归一 8
    public var shadowLimitJdb: Int = 80000       // 0 = 不限；旧哨兵归一 0
    public var shadowLimitSht: Int = 150000      // 同上
    public var semThreshold: Int = 10            // 语义阈值 ×100（0.10f）
    public var embCacheMb: Int = 100             // 0 = 不限
    public var viewMode: Int = 0                 // P4：0=小图 1=大图 2=列表；迁移源 big
    public var coverHalf: Int = 0                // 0=右半 1=左半 2=整张
    public var lookupScope: Int = 0              // P8：0=最近 2 万部内 1=全库
    public var searchMode: Int = 1               // P5：0=精确 1=模糊
    /// 远程筛选 taxonomy 最后更新（秒；落盘 Int，上层读 Int64）
    public var taxonomyTs: Int64 = 0
    public var shadowMode: Int = 1               // S12-P0：0=完整 1=仅索引
    public var homePer: Int = 24                 // S12-P0：档位 {12,18,24,36}，档位外归一 24

    // MARK: - Boolean 键（18，KB 表）

    public var big: Bool = false                 // 旧版大图开关：仅作 view_mode 迁移源，键保留不删
    public var shtBig: Bool = false
    public var shtHasMagnet: Bool = false
    public var rdAlt: Bool = false
    public var proxyDb: Bool = false             // 数据库 (SOCKS) 代理
    public var proxyCdn: Bool = false            // 图片 CDN (HTTP) 代理；新键迁移源，键保留不删
    public var lockEnabled: Bool = false         // 启动锁总开关
    public var dbSsl: Bool = true                // A-14：旧 false → true
    public var newPipeline: Bool = true          // S1：新数据管线总开关
    public var shadowEnabled: Bool = true        // S3：离线索引开关
    public var shadowPrefer: Bool = false        // P3：离线优先，默认关
    public var jdbSortAsc: Bool = false          // S11-P2：false=倒序；不纳入 autoSave dbChanged
    public var proxyCdnJdb: Bool = false         // S11-P7：未落盘沿用旧 proxy_cdn
    public var proxyCdnSht: Bool = false         // S11-P7：同上
    public var testImgMode: Bool = false         // S11-P8：测试图片模式（仅 debug 暴露）
    public var shadowActorIndex: Bool = true     // S13-P3：女优索引开关
    public var shadowActorLinks: Bool = true     // S13-P3：出演关系开关
    public var shadowTagIndex: Bool = true       // S14-P7：影片标签索引

    public init() {}
}

// MARK: - 键名常量表（DataStore 键名逐字，顺序即 B 表 1..72）

public extension AppSettings {
    /// String 键（30）
    static let KS: [String] = [
        "db_src", "local_host", "local_port", "local_user", "local_pass",
        "local_jdb", "local_sht", "remote_host", "remote_port", "remote_user",
        "remote_pass", "remote_jdb", "remote_sht", "theme_name", "theme_accent",
        "jdb_sort", "actor_sort", "actor_gender", "rd_font_family", "rd_bg_color",
        "rd_fg_color", "rd_alt_a", "rd_alt_b", "proxy_host", "proxy_port",
        "jdb_img_host", "sht_mirror", "sht_mirror_host", "lock_type", "lock_secret",
    ]
    /// Int 键（24）
    static let KI: [String] = [
        "per_page", "sht_per", "rd_font_pt", "rd_line_height", "rd_paragraph",
        "home_ttl", "cat_ttl", "filter_ttl", "image_cache_mb", "image_cache_days",
        "sem_cand", "connect_timeout", "query_timeout", "shadow_limit_jdb",
        "shadow_limit_sht", "sem_threshold", "emb_cache_mb", "view_mode",
        "cover_half", "lookup_scope", "search_mode", "taxonomy_ts", "shadow_mode",
        "home_per",
    ]
    /// Boolean 键（18）
    static let KB: [String] = [
        "big", "sht_big", "sht_has_magnet", "rd_alt", "proxy_db", "proxy_cdn",
        "lock_enabled", "db_ssl", "new_pipeline", "shadow_enabled", "shadow_prefer",
        "jdb_sort_asc", "proxy_cdn_jdb", "proxy_cdn_sht", "test_img_mode",
        "shadow_actor_index", "shadow_actor_links", "shadow_tag_index",
    ]

    /// 口令键（Store 落盘 UserDefaults 前剔除；remote_pass/local_pass 经 Keychain，
    /// lock_secret 存 Keychain 的是 PBKDF2 哈希）
    static let secretStorageKeys: Set<String> = ["remote_pass", "local_pass", "lock_secret"]

    /// 档位表（B.5 规则 1/2 + A10/R9 connect_timeout 对齐 UI chips [4,8,15,30]）
    static let QUERY_TIMEOUT_OPTS: Set<Int> = [4, 8, 15, 30]
    static let CONNECT_TIMEOUT_OPTS: Set<Int> = [4, 8, 15, 30]
    static let HOME_PER_OPTS: Set<Int> = [12, 18, 24, 36]
}

// MARK: - 派生 getter（不落盘，B.8；按 dbSrc == "local" 切换 local/remote 组）

public extension AppSettings {
    var isLocal: Bool { dbSrc == "local" }

    var host: String { dbSrc == "local" ? localHost : remoteHost }
    var port: String { dbSrc == "local" ? localPort : remotePort }
    var user: String { dbSrc == "local" ? localUser : remoteUser }
    var pass: String { dbSrc == "local" ? localPass : remotePass }
    var jdbDb: String { dbSrc == "local" ? localJdb : remoteJdb }
    var shtDb: String { dbSrc == "local" ? localSht : remoteSht }

    /// 首启引导判定（07 §A2 + A8/R8 加固）：
    /// remote → host/port/jdb/sht/user/pass 合法（端口可解析且在 1..65535，字段非空）；
    /// local  → localHost/localPort/jdb/sht/localUser 合法。
    /// 不再「只看 user/pass 非空」—— 错误默认端口/空库名不放行进生产首页。
    var setupRequired: Bool {
        if dbSrc == "remote" {
            return remoteUser.isEmpty || remotePass.isEmpty
                || remoteHost.isEmpty || remoteJdb.isEmpty || remoteSht.isEmpty
                || !Self.portValid(remotePort)
        }
        return localUser.isEmpty
            || localHost.isEmpty || localJdb.isEmpty || localSht.isEmpty
            || !Self.portValid(localPort)
    }

    private static func portValid(_ p: String) -> Bool {
        guard let n = Int(p), n > 0, n <= 65535 else { return false }
        return true
    }
}

// MARK: - 归一化（B.5 规则 1/2/3，flow 读取处）

public extension AppSettings {
    /// 读取归一：query_timeout/connect_timeout 档位外回默认 8；home_per 档位外回默认；
    /// 上限旧哨兵 ≥ Int32.max/2 → 0（=不限）
    func normalized() -> AppSettings {
        var s = self
        if !Self.QUERY_TIMEOUT_OPTS.contains(s.queryTimeout) { s.queryTimeout = 8 }
        if !Self.CONNECT_TIMEOUT_OPTS.contains(s.connectTimeout) { s.connectTimeout = 8 }
        if !Self.HOME_PER_OPTS.contains(s.homePer) { s.homePer = 24 }
        s.shadowLimitJdb = LimitMath.normalizeStored(s.shadowLimitJdb)
        s.shadowLimitSht = LimitMath.normalizeStored(s.shadowLimitSht)
        return s
    }
}

// MARK: - 存储编解码（fromStorage 迁移 + toStorage 全量 72 键 + JSON 单键视图）

public extension AppSettings {
    /// 行取值助手：String（缺省回默认；非字符串宽松转描述，等价 Q.s 的宽容语义）
    private static func readS(_ d: [String: Any], _ k: String, _ def: String) -> String {
        switch d[k] {
        case let v as String: return v
        case let v as CustomStringConvertible: return String(describing: v)
        default: return def
        }
    }

    /// 行取值助手：Int（Number 优先按数值转，否则字符串解析，兜底默认；等价 Q.i）。
    /// NSNumber 分支兜住 JSON 往返（Darwin 走桥接在前几支命中，Linux corelibs 走本支）。
    private static func readI(_ d: [String: Any], _ k: String, _ def: Int) -> Int {
        switch d[k] {
        case let v as Int: return v
        case let v as Int64: return Int(truncatingIfNeeded: v)
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as Bool: return v ? 1 : 0
        case let v as String: return Int(v) ?? def
        default: return def
        }
    }

    /// 行取值助手：Bool（Boolean 原样；Number 判 ==1；String 判 "1"/忽略大小写 "true"；等价 Q.b）
    private static func readB(_ d: [String: Any], _ k: String, _ def: Bool) -> Bool {
        switch d[k] {
        case let v as Bool: return v
        case let v as NSNumber: return v.intValue == 1
        case let v as Int: return v == 1
        case let v as Int64: return v == 1
        case let v as Double: return v == 1
        case let v as String: return v == "1" || v.lowercased() == "true"
        default: return def
        }
    }

    /// 从存储字典构建（含迁移与归一，对齐 Prefs flow 读取处）。
    /// `d` 的值域：String / Int / Int64 / Double / Bool / NSNumber / NSNull（JSON 往返安全）。
    static func fromStorage(_ d: [String: Any]) -> AppSettings {
        var s = AppSettings()

        // 30 KS
        s.dbSrc = readS(d, "db_src", s.dbSrc)
        s.localHost = readS(d, "local_host", s.localHost)
        s.localPort = readS(d, "local_port", s.localPort)
        s.localUser = readS(d, "local_user", s.localUser)
        s.localPass = readS(d, "local_pass", s.localPass)
        s.localJdb = readS(d, "local_jdb", s.localJdb)
        s.localSht = readS(d, "local_sht", s.localSht)
        s.remoteHost = readS(d, "remote_host", s.remoteHost)
        s.remotePort = readS(d, "remote_port", s.remotePort)
        s.remoteUser = readS(d, "remote_user", s.remoteUser)
        s.remotePass = readS(d, "remote_pass", s.remotePass)
        s.remoteJdb = readS(d, "remote_jdb", s.remoteJdb)
        s.remoteSht = readS(d, "remote_sht", s.remoteSht)
        s.themeName = readS(d, "theme_name", s.themeName)
        s.themeAccent = readS(d, "theme_accent", s.themeAccent)
        s.jdbSort = readS(d, "jdb_sort", s.jdbSort)
        s.actorSort = readS(d, "actor_sort", s.actorSort)
        s.actorGender = readS(d, "actor_gender", s.actorGender)
        s.rdFontFamily = readS(d, "rd_font_family", s.rdFontFamily)
        s.rdBgColor = readS(d, "rd_bg_color", s.rdBgColor)
        s.rdFgColor = readS(d, "rd_fg_color", s.rdFgColor)
        s.rdAltA = readS(d, "rd_alt_a", s.rdAltA)
        s.rdAltB = readS(d, "rd_alt_b", s.rdAltB)
        s.proxyHost = readS(d, "proxy_host", s.proxyHost)
        s.proxyPort = readS(d, "proxy_port", s.proxyPort)
        s.jdbImgHost = readS(d, "jdb_img_host", s.jdbImgHost)
        s.shtMirror = readS(d, "sht_mirror", s.shtMirror)
        s.shtMirrorHost = readS(d, "sht_mirror_host", s.shtMirrorHost)
        s.lockType = readS(d, "lock_type", s.lockType)
        s.lockSecret = readS(d, "lock_secret", s.lockSecret)

        // 24 KI（rd_line_height / rd_paragraph 为 ×10 的 Int；taxonomy_ts 秒级 Int → Int64）
        s.perPage = readI(d, "per_page", s.perPage)
        s.shtPer = readI(d, "sht_per", s.shtPer)
        s.rdFontPt = readI(d, "rd_font_pt", s.rdFontPt)
        s.rdLineHeight = Float(readI(d, "rd_line_height", Int(s.rdLineHeight * 10))) / 10.0
        s.rdParagraph = Float(readI(d, "rd_paragraph", Int(s.rdParagraph * 10))) / 10.0
        s.homeTtl = readI(d, "home_ttl", s.homeTtl)
        s.catTtl = readI(d, "cat_ttl", s.catTtl)
        s.filterTtl = readI(d, "filter_ttl", s.filterTtl)
        s.imageCacheMb = readI(d, "image_cache_mb", s.imageCacheMb)
        s.imageCacheDays = readI(d, "image_cache_days", s.imageCacheDays)
        s.semCand = readI(d, "sem_cand", s.semCand)
        s.connectTimeout = readI(d, "connect_timeout", s.connectTimeout)
        s.queryTimeout = readI(d, "query_timeout", s.queryTimeout)
        s.shadowLimitJdb = readI(d, "shadow_limit_jdb", s.shadowLimitJdb)
        s.shadowLimitSht = readI(d, "shadow_limit_sht", s.shadowLimitSht)
        s.semThreshold = readI(d, "sem_threshold", s.semThreshold)
        s.embCacheMb = readI(d, "emb_cache_mb", s.embCacheMb)
        s.coverHalf = readI(d, "cover_half", s.coverHalf)
        s.lookupScope = readI(d, "lookup_scope", s.lookupScope)
        s.searchMode = readI(d, "search_mode", s.searchMode)
        s.taxonomyTs = Int64(readI(d, "taxonomy_ts", Int(s.taxonomyTs)))
        s.shadowMode = readI(d, "shadow_mode", s.shadowMode)
        s.homePer = readI(d, "home_per", s.homePer)

        // 18 KB + 迁移（B.5 规则 4/5）
        s.big = readB(d, "big", s.big)
        s.shtBig = readB(d, "sht_big", s.shtBig)
        s.shtHasMagnet = readB(d, "sht_has_magnet", s.shtHasMagnet)
        s.rdAlt = readB(d, "rd_alt", s.rdAlt)
        s.proxyDb = readB(d, "proxy_db", s.proxyDb)
        s.proxyCdn = readB(d, "proxy_cdn", s.proxyCdn)
        s.lockEnabled = readB(d, "lock_enabled", s.lockEnabled)
        s.dbSsl = readB(d, "db_ssl", s.dbSsl)
        s.newPipeline = readB(d, "new_pipeline", s.newPipeline)
        s.shadowEnabled = readB(d, "shadow_enabled", s.shadowEnabled)
        s.shadowPrefer = readB(d, "shadow_prefer", s.shadowPrefer)
        s.jdbSortAsc = readB(d, "jdb_sort_asc", s.jdbSortAsc)
        s.testImgMode = readB(d, "test_img_mode", s.testImgMode)
        s.shadowActorIndex = readB(d, "shadow_actor_index", s.shadowActorIndex)
        s.shadowActorLinks = readB(d, "shadow_actor_links", s.shadowActorLinks)
        s.shadowTagIndex = readB(d, "shadow_tag_index", s.shadowTagIndex)
        // view_mode：未落盘（旧版）按旧 big 布尔换算：big=true → 1（大图），false → 0（小图）
        let rawViewMode = readI(d, "view_mode", -1)
        s.viewMode = rawViewMode >= 0 ? rawViewMode : (s.big ? 1 : 0)
        // proxy_cdn_jdb / proxy_cdn_sht：新键未落盘时沿用旧 proxy_cdn（旧用户无感）
        s.proxyCdnJdb = readB(d, "proxy_cdn_jdb", readB(d, "proxy_cdn", s.proxyCdn))
        s.proxyCdnSht = readB(d, "proxy_cdn_sht", readB(d, "proxy_cdn", s.proxyCdn))

        return s.normalized()
    }

    /// 全量 72 键输出（键名 snake_case 逐字）。口令键由 Store 落盘前剔除（storageWithoutSecrets）。
    func toStorage() -> [String: Any] {
        var d: [String: Any] = [:]
        // 30 KS
        d["db_src"] = dbSrc
        d["local_host"] = localHost
        d["local_port"] = localPort
        d["local_user"] = localUser
        d["local_pass"] = localPass
        d["local_jdb"] = localJdb
        d["local_sht"] = localSht
        d["remote_host"] = remoteHost
        d["remote_port"] = remotePort
        d["remote_user"] = remoteUser
        d["remote_pass"] = remotePass
        d["remote_jdb"] = remoteJdb
        d["remote_sht"] = remoteSht
        d["theme_name"] = themeName
        d["theme_accent"] = themeAccent
        d["jdb_sort"] = jdbSort
        d["actor_sort"] = actorSort
        d["actor_gender"] = actorGender
        d["rd_font_family"] = rdFontFamily
        d["rd_bg_color"] = rdBgColor
        d["rd_fg_color"] = rdFgColor
        d["rd_alt_a"] = rdAltA
        d["rd_alt_b"] = rdAltB
        d["proxy_host"] = proxyHost
        d["proxy_port"] = proxyPort
        d["jdb_img_host"] = jdbImgHost
        d["sht_mirror"] = shtMirror
        d["sht_mirror_host"] = shtMirrorHost
        d["lock_type"] = lockType
        d["lock_secret"] = lockSecret
        // 24 KI
        d["per_page"] = perPage
        d["sht_per"] = shtPer
        d["rd_font_pt"] = rdFontPt
        d["rd_line_height"] = Int(rdLineHeight * 10)              // Float×10 存 Int
        d["rd_paragraph"] = Int(rdParagraph * 10)                 // 同上
        d["home_ttl"] = homeTtl
        d["cat_ttl"] = catTtl
        d["filter_ttl"] = filterTtl
        d["image_cache_mb"] = imageCacheMb
        d["image_cache_days"] = imageCacheDays
        d["sem_cand"] = semCand
        d["connect_timeout"] = connectTimeout
        d["query_timeout"] = queryTimeout
        d["shadow_limit_jdb"] = shadowLimitJdb
        d["shadow_limit_sht"] = shadowLimitSht
        d["sem_threshold"] = semThreshold
        d["emb_cache_mb"] = embCacheMb
        d["view_mode"] = viewMode
        d["cover_half"] = coverHalf
        d["lookup_scope"] = lookupScope
        d["search_mode"] = searchMode
        d["taxonomy_ts"] = Int(min(max(taxonomyTs, 0), Int64(Int32.max)))  // 秒级 Int，clamp [0, Int32.max]
        d["shadow_mode"] = shadowMode
        d["home_per"] = homePer
        // 18 KB
        d["big"] = big
        d["sht_big"] = shtBig
        d["sht_has_magnet"] = shtHasMagnet
        d["rd_alt"] = rdAlt
        d["proxy_db"] = proxyDb
        d["proxy_cdn"] = proxyCdn
        d["lock_enabled"] = lockEnabled
        d["db_ssl"] = dbSsl
        d["new_pipeline"] = newPipeline
        d["shadow_enabled"] = shadowEnabled
        d["shadow_prefer"] = shadowPrefer
        d["jdb_sort_asc"] = jdbSortAsc
        d["proxy_cdn_jdb"] = proxyCdnJdb
        d["proxy_cdn_sht"] = proxyCdnSht
        d["test_img_mode"] = testImgMode
        d["shadow_actor_index"] = shadowActorIndex
        d["shadow_actor_links"] = shadowActorLinks
        d["shadow_tag_index"] = shadowTagIndex
        return d
    }

    /// Store 落盘视图：剔除口令键（口令走 Keychain，绝不进 UserDefaults）
    var storageWithoutSecrets: [String: Any] {
        var d = toStorage()
        for k in Self.secretStorageKeys { d.removeValue(forKey: k) }
        return d
    }
}

// MARK: - JSONRepresentation（iOS 刻意简化：所有值 JSON 编码后存 UserDefaults 单键）

public extension AppSettings {
    /// UserDefaults 单键（对齐 Android DataStore 文件名 `jdlv_settings` 的版本化变体）
    static let storageDefaultsKey = "jdlv_settings_v1"

    /// [String: Any] → JSON Data（值域 String/Int/Bool，恒可序列化；失败返回 nil）
    static func encodeStorageJSON(_ storage: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys])
    }

    /// JSON Data → [String: Any]
    static func decodeStorageJSON(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// 从 JSON Data 构建（含口令键缺失容错：fromStorage 对缺键回默认）
    static func fromStorageJSON(_ data: Data) -> AppSettings {
        guard let d = decodeStorageJSON(data) else { return AppSettings() }
        return fromStorage(d)
    }
}
