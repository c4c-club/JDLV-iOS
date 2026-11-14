//
//  SettingsTests.swift
//  JDLVCoreTests
//
//  对应规格: docs/_extract/13_theme_prefs_models.md §B（72 键全表 + 五条归一化迁移规则）、
//           docs/_extract/02_q_db.md §0.1（normalizePer）、07 §A2（setupRequired）。
//  被测: JDLVCore.AppSettings（字段默认值逐字 / 键名逐字 / fromStorage 迁移 / toStorage 往返 /
//        storageWithoutSecrets 口令剔除 / JSON 单键视图 / 派生 getter）
//
//  Linux 兼容: 纯 Foundation 同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class SettingsTests: XCTestCase {

    // MARK: - 键表结构（R4 S1：73 = String 30 + Int 24 + Boolean 19）

    /// KS 30 / KI 24 / KB 19，合计 73，互不重叠且并集即 73
    func test_keyTableCounts() {
        XCTAssertEqual(AppSettings.KS.count, 30)
        XCTAssertEqual(AppSettings.KI.count, 24)
        XCTAssertEqual(AppSettings.KB.count, 19)
        XCTAssertEqual(AppSettings.KS.count + AppSettings.KI.count + AppSettings.KB.count, 73)
        let all = Set(AppSettings.KS).union(AppSettings.KI).union(AppSettings.KB)
        XCTAssertEqual(all.count, 73)
    }

    /// 键名逐字抽查（含易错的下划线/拼写）
    func test_keyNamesVerbatim() {
        XCTAssertEqual(AppSettings.KS.first, "db_src")
        XCTAssertEqual(AppSettings.KS.last, "lock_secret")
        XCTAssertTrue(AppSettings.KS.contains("remote_port"))
        XCTAssertTrue(AppSettings.KS.contains("jdb_img_host"))
        XCTAssertTrue(AppSettings.KS.contains("sht_mirror_host"))
        XCTAssertTrue(AppSettings.KS.contains("theme_accent"))
        XCTAssertTrue(AppSettings.KI.contains("rd_line_height"))
        XCTAssertTrue(AppSettings.KI.contains("shadow_limit_jdb"))
        XCTAssertTrue(AppSettings.KI.contains("taxonomy_ts"))
        XCTAssertTrue(AppSettings.KI.contains("home_per"))
        XCTAssertTrue(AppSettings.KB.contains("proxy_cdn_jdb"))
        XCTAssertTrue(AppSettings.KB.contains("sht_has_magnet"))
        XCTAssertTrue(AppSettings.KB.contains("shadow_actor_links"))
        XCTAssertTrue(AppSettings.KB.contains("test_img_mode"))
        XCTAssertTrue(AppSettings.KB.contains("jdb_sort_asc"))
        XCTAssertTrue(AppSettings.KB.contains("allow_insecure_http"), "R4 S1 新键")
    }

    /// R4 S1：明文 HTTP 镜像开关默认必须 false（绝不偷偷默认 true）
    func test_allowInsecureHTTPDefaultsFalse() {
        XCTAssertEqual(AppSettings().allowInsecureHTTP, false, "S1：默认禁止明文 HTTP 镜像")
        let d = AppSettings().toStorage()
        XCTAssertEqual(d["allow_insecure_http"] as? Bool, false, "落盘视图默认 false")
    }

    // MARK: - 默认值逐字抽查（B 表，≥10 项）

    /// init 默认值逐项照 13_extract B 表（String/Int/Boolean 三组全抽样）
    func test_defaultsSpotCheck() {
        let s = AppSettings()
        // String
        XCTAssertEqual(s.dbSrc, "remote")
        XCTAssertEqual(s.localHost, "127.0.0.1")
        XCTAssertEqual(s.localPort, "3306")
        XCTAssertEqual(s.localUser, "")
        XCTAssertEqual(s.remoteHost, "")             // R4：不预置内网地址
        XCTAssertEqual(s.remotePort, "3306")
        XCTAssertEqual(s.remoteJdb, "javdb")
        XCTAssertEqual(s.remoteSht, "sehuatang")
        XCTAssertEqual(s.themeName, "dark")
        XCTAssertEqual(s.themeAccent, "紫")
        XCTAssertEqual(s.jdbSort, "release_date")
        XCTAssertEqual(s.actorSort, "videos")
        XCTAssertEqual(s.actorGender, "f")
        XCTAssertEqual(s.rdAltB, "#9aa0ad")
        XCTAssertEqual(s.proxyPort, "7890")
        XCTAssertEqual(s.jdbImgHost, "app")
        XCTAssertEqual(s.lockType, "none")
        XCTAssertEqual(s.lockSecret, "")
        // Int
        XCTAssertEqual(s.perPage, 40)
        XCTAssertEqual(s.shtPer, 20)
        XCTAssertEqual(s.rdFontPt, 16)
        XCTAssertEqual(s.rdLineHeight, 2.0)
        XCTAssertEqual(s.rdParagraph, 1.0)
        XCTAssertEqual(s.homeTtl, 10)
        XCTAssertEqual(s.catTtl, 10)
        XCTAssertEqual(s.filterTtl, 60)
        XCTAssertEqual(s.imageCacheMb, 128)
        XCTAssertEqual(s.imageCacheDays, 30)
        XCTAssertEqual(s.semCand, 3000)
        XCTAssertEqual(s.connectTimeout, 8)   // A10/R9：默认对齐 UI 档位 {4,8,15,30}（旧 5 档位外归一 8）
        XCTAssertEqual(s.queryTimeout, 8)
        XCTAssertEqual(s.shadowLimitJdb, 80000)
        XCTAssertEqual(s.shadowLimitSht, 150000)
        XCTAssertEqual(s.semThreshold, 10)
        XCTAssertEqual(s.embCacheMb, 100)
        XCTAssertEqual(s.viewMode, 0)
        XCTAssertEqual(s.coverHalf, 0)
        XCTAssertEqual(s.lookupScope, 0)
        XCTAssertEqual(s.searchMode, 1)
        XCTAssertEqual(s.taxonomyTs, 0)
        XCTAssertEqual(s.shadowMode, 1)
        XCTAssertEqual(s.homePer, 24)
        // Boolean
        XCTAssertFalse(s.big)
        XCTAssertFalse(s.shtBig)
        XCTAssertFalse(s.shtHasMagnet)
        XCTAssertFalse(s.rdAlt)
        XCTAssertFalse(s.proxyDb)
        XCTAssertFalse(s.proxyCdn)
        XCTAssertFalse(s.lockEnabled)
        XCTAssertTrue(s.dbSsl)
        XCTAssertTrue(s.newPipeline)
        XCTAssertTrue(s.shadowEnabled)
        XCTAssertFalse(s.shadowPrefer)
        XCTAssertFalse(s.jdbSortAsc)
        XCTAssertFalse(s.proxyCdnJdb)
        XCTAssertFalse(s.proxyCdnSht)
        XCTAssertFalse(s.testImgMode)
        XCTAssertTrue(s.shadowActorIndex)
        XCTAssertTrue(s.shadowActorLinks)
        XCTAssertTrue(s.shadowTagIndex)
    }

    // MARK: - 归一化（B.5 规则 1/2/3，三组）

    /// 规则 1：query_timeout 档位 {4,8,15,30}，档位外（0/20/60/999）归一 8
    func test_normalize_queryTimeoutOffLadderTo8() {
        XCTAssertEqual(AppSettings().normalized().queryTimeout, 8)
        func norm(_ v: Int) -> Int {
            var s = AppSettings(); s.queryTimeout = v; return s.normalized().queryTimeout
        }
        XCTAssertEqual(norm(20), 8)   // 旧档位
        XCTAssertEqual(norm(60), 8)   // 旧档位
        XCTAssertEqual(norm(0), 8)
        XCTAssertEqual(norm(999), 8)
        XCTAssertEqual(norm(4), 4)
        XCTAssertEqual(norm(8), 8)
        XCTAssertEqual(norm(15), 15)
        XCTAssertEqual(norm(30), 30)
    }

    /// 规则 2：home_per 档位 {12,18,24,36}，档位外归一 24
    func test_normalize_homePerOffLadderTo24() {
        func norm(_ v: Int) -> Int {
            var s = AppSettings(); s.homePer = v; return s.normalized().homePer
        }
        XCTAssertEqual(norm(20), 24)  // 12/18/24/36 之外
        XCTAssertEqual(norm(30), 24)
        XCTAssertEqual(norm(0), 24)
        XCTAssertEqual(norm(-5), 24)
        XCTAssertEqual(norm(12), 12)
        XCTAssertEqual(norm(18), 18)
        XCTAssertEqual(norm(24), 24)
        XCTAssertEqual(norm(36), 36)
    }

    /// 规则 3：上限哨兵 ≥ Int32.max/2 → 0（=不限）；0 与正常值不变
    func test_normalize_unlimitedSentinelCollapsesToZero() {
        func normJ(_ v: Int) -> Int {
            var s = AppSettings(); s.shadowLimitJdb = v; return s.normalized().shadowLimitJdb
        }
        func normS(_ v: Int) -> Int {
            var s = AppSettings(); s.shadowLimitSht = v; return s.normalized().shadowLimitSht
        }
        let mark = Int(Int32.max / 2)   // 1,073,741,823
        XCTAssertEqual(normJ(Int.max), 0)
        XCTAssertEqual(normJ(mark), 0)
        XCTAssertEqual(normJ(mark - 1), mark - 1)
        XCTAssertEqual(normJ(0), 0)
        XCTAssertEqual(normJ(80000), 80000)
        XCTAssertEqual(normS(Int.max), 0)
        XCTAssertEqual(normS(mark), 0)
        XCTAssertEqual(normS(150000), 150000)
    }

    // MARK: - 迁移（B.5 规则 4/5，两组）

    /// 规则 4：view_mode 未落盘时按旧 big 布尔换算；落盘值优先生效；big 键保留不删
    func test_migrate_viewModeFromBig() {
        // 未落盘 + big=true → 1（大图）
        let fromBig = AppSettings.fromStorage(["big": true])
        XCTAssertEqual(fromBig.viewMode, 1)
        XCTAssertEqual(fromBig.big, true)
        // 未落盘 + big 缺省（false）→ 0（小图）
        XCTAssertEqual(AppSettings.fromStorage([:]).viewMode, 0)
        XCTAssertEqual(AppSettings.fromStorage(["big": false]).viewMode, 0)
        // 已落盘优先，big 被忽略
        XCTAssertEqual(AppSettings.fromStorage(["view_mode": 2, "big": true]).viewMode, 2)
        XCTAssertEqual(AppSettings.fromStorage(["view_mode": 0, "big": true]).viewMode, 0)
    }

    /// 规则 5：proxy_cdn_jdb / proxy_cdn_sht 未落盘时回填旧 proxy_cdn；新键落盘则优先
    func test_migrate_proxyCdnBackfill() {
        // 旧用户 proxy_cdn=true → 两个新键都沿用 true
        let old = AppSettings.fromStorage(["proxy_cdn": true])
        XCTAssertTrue(old.proxyCdnJdb)
        XCTAssertTrue(old.proxyCdnSht)
        XCTAssertTrue(old.proxyCdn)  // 旧键保留
        // 旧 proxy_cdn=false 且新键未落盘 → false
        let off = AppSettings.fromStorage(["proxy_cdn": false])
        XCTAssertFalse(off.proxyCdnJdb)
        XCTAssertFalse(off.proxyCdnSht)
        // 新键未落盘且旧键也缺 → 默认 false
        let fresh = AppSettings.fromStorage([:])
        XCTAssertFalse(fresh.proxyCdnJdb)
        XCTAssertFalse(fresh.proxyCdnSht)
        // 新键已落盘 → 不再回填（分别独立）
        let split = AppSettings.fromStorage(["proxy_cdn": true, "proxy_cdn_jdb": false])
        XCTAssertFalse(split.proxyCdnJdb)
        XCTAssertTrue(split.proxyCdnSht)
    }

    // MARK: - Float×10 与 taxonomy_ts 存取口径（B.5 规则 6/7）

    /// rd_line_height / rd_paragraph 落盘 ×10 的 Int，读取 /10f
    func test_storage_floatTimesTen() {
        var s = AppSettings()
        XCTAssertEqual(s.toStorage()["rd_line_height"] as? Int, 20)
        XCTAssertEqual(s.toStorage()["rd_paragraph"] as? Int, 10)
        s.rdLineHeight = 2.5
        s.rdParagraph = 1.8
        let back = AppSettings.fromStorage(s.toStorage())
        XCTAssertEqual(back.rdLineHeight, 2.5)
        XCTAssertEqual(back.rdParagraph, 1.8, accuracy: 0.0001)
    }

    /// taxonomy_ts 落盘秒级 Int，写时 clamp [0, Int32.max]，读为 Int64
    func test_storage_taxonomyTsSecondsInt() {
        var s = AppSettings()
        s.taxonomyTs = 1_234_567_890
        XCTAssertEqual(s.toStorage()["taxonomy_ts"] as? Int, 1_234_567_890)
        XCTAssertEqual(AppSettings.fromStorage(s.toStorage()).taxonomyTs, 1_234_567_890)
        s.taxonomyTs = 3_000_000_000        // 超 Int32
        XCTAssertEqual(s.toStorage()["taxonomy_ts"] as? Int, 2_147_483_647)
        s.taxonomyTs = -5
        XCTAssertEqual(s.toStorage()["taxonomy_ts"] as? Int, 0)
    }

    // MARK: - toStorage/fromStorage 往返 + 口令剔除

    /// 全量 72 键输出；改值后往返字段全等（含口令字段本体在 Core 层可往返）
    func test_roundTrip_toStorage_fromStorage() {
        var s = AppSettings()
        s.dbSrc = "local"
        s.localUser = "root"
        s.localPass = "pw-local"
        s.remoteHost = "10.0.0.2"
        s.remotePort = "3308"
        s.remoteUser = "reader"
        s.remotePass = "pw-remote"
        s.themeName = "sepia"
        s.themeAccent = "青"
        s.jdbSortAsc = true
        s.viewMode = 2
        s.queryTimeout = 30
        s.homePer = 36
        s.shadowLimitJdb = 200000
        s.lockEnabled = true
        s.lockType = "pin"
        s.lockSecret = "pbkdf2-sha256$120000$abc$def"

        let storage = s.toStorage()
        XCTAssertEqual(storage.count, 73)   // R4 S1：+allow_insecure_http
        let back = AppSettings.fromStorage(storage)
        XCTAssertEqual(back, s)
    }

    /// 口令键剔除：storageWithoutSecrets 恰 69 键且不含 remote_pass/local_pass/lock_secret
    func test_storageWithoutSecrets() {
        var s = AppSettings()
        s.remotePass = "pw-remote"
        s.localPass = "pw-local"
        s.lockSecret = "hash"
        let stripped = s.storageWithoutSecrets
        XCTAssertEqual(stripped.count, 70)   // R4 S1：73 − 3 口令键
        XCTAssertNil(stripped["remote_pass"])
        XCTAssertNil(stripped["local_pass"])
        XCTAssertNil(stripped["lock_secret"])
        // 非口令键仍在
        XCTAssertEqual(stripped["remote_host"] as? String, AppSettings().remoteHost)
        XCTAssertEqual(stripped["lock_type"] as? String, "none")
    }

    /// JSON 单键视图往返：JSON 编码/解码后字段全等；口令键不出现在 JSON 中
    func test_jsonRepresentationRoundTrip() {
        var s = AppSettings()
        s.themeName = "light"
        s.themeAccent = "蓝"
        s.remoteHost = "192.168.1.50"
        s.remotePort = "3307"
        s.remoteUser = "reader"
        s.remotePass = "secret-do-not-persist"
        s.queryTimeout = 15
        s.homePer = 18
        s.imageCacheMb = 256
        s.proxyDb = true
        s.rdLineHeight = 1.6
        s.taxonomyTs = 1_700_000_000

        let data = AppSettings.encodeStorageJSON(s.storageWithoutSecrets)
        XCTAssertNotNil(data)
        let json = String(data: data!, encoding: .utf8)!
        XCTAssertFalse(json.contains("secret-do-not-persist"))
        XCTAssertFalse(json.contains("local_pass"))
        XCTAssertFalse(json.contains("remote_pass"))
        XCTAssertFalse(json.contains("lock_secret"))

        let back = AppSettings.fromStorageJSON(data!)
        XCTAssertEqual(back.themeName, "light")
        XCTAssertEqual(back.themeAccent, "蓝")
        XCTAssertEqual(back.remoteHost, "192.168.1.50")
        XCTAssertEqual(back.remotePort, "3307")
        XCTAssertEqual(back.remoteUser, "reader")
        XCTAssertEqual(back.remotePass, "")          // 口令不落盘 → 读回默认空
        XCTAssertEqual(back.queryTimeout, 15)
        XCTAssertEqual(back.homePer, 18)
        XCTAssertEqual(back.imageCacheMb, 256)
        XCTAssertEqual(back.proxyDb, true)
        XCTAssertEqual(back.rdLineHeight, 1.6, accuracy: 0.0001)
        XCTAssertEqual(back.taxonomyTs, 1_700_000_000)
    }

    /// 损坏 JSON / 空字典容错：回默认（且归一化生效）
    func test_fromStorage_faultTolerance() {
        let garbage = Data("not-json".utf8)
        XCTAssertEqual(AppSettings.fromStorageJSON(garbage), AppSettings())
        // 旧非法档位经 JSON 读取也被归一
        let dict = AppSettings.decodeStorageJSON(AppSettings.encodeStorageJSON([
            "query_timeout": 60, "home_per": 20, "shadow_limit_jdb": Int.max,
        ])!)!
        let s = AppSettings.fromStorage(dict)
        XCTAssertEqual(s.queryTimeout, 8)
        XCTAssertEqual(s.homePer, 24)
        XCTAssertEqual(s.shadowLimitJdb, 0)
        // 未知键被忽略
        XCTAssertEqual(AppSettings.fromStorage(["unknown_key": 1]), AppSettings())
    }

    // MARK: - 派生 getter 与 setupRequired（B.8 / 07 §A2）

    /// host/port/user/pass/jdbDb/shtDb 按 dbSrc 切换 local/remote 组
    func test_derivedGettersSwitchByDbSrc() {
        var s = AppSettings()
        s.localHost = "1.1.1.1"; s.localPort = "1"; s.localUser = "lu"
        s.localPass = "lp"; s.localJdb = "lj"; s.localSht = "ls"
        s.remoteHost = "2.2.2.2"; s.remotePort = "2"; s.remoteUser = "ru"
        s.remotePass = "rp"; s.remoteJdb = "rj"; s.remoteSht = "rs"

        s.dbSrc = "local"
        XCTAssertEqual(s.host, "1.1.1.1"); XCTAssertEqual(s.port, "1")
        XCTAssertEqual(s.user, "lu"); XCTAssertEqual(s.pass, "lp")
        XCTAssertEqual(s.jdbDb, "lj"); XCTAssertEqual(s.shtDb, "ls")

        s.dbSrc = "remote"
        XCTAssertEqual(s.host, "2.2.2.2"); XCTAssertEqual(s.port, "2")
        XCTAssertEqual(s.user, "ru"); XCTAssertEqual(s.pass, "rp")
        XCTAssertEqual(s.jdbDb, "rj"); XCTAssertEqual(s.shtDb, "rs")
    }

    /// setupRequired：remote → host/user/pass 任一空；local → localUser 空（pass 不参与）
    /// R4 V10：默认 remoteHost=""（不预置内网地址）→ host 也是 setup 判定项，测试注入
    func test_setupRequired() {
        var s = AppSettings()
        XCTAssertTrue(s.setupRequired)                 // 默认 remote + host/账号空
        s.remoteHost = "10.0.0.5"
        XCTAssertTrue(s.setupRequired)                 // 账号仍空
        s.remoteUser = "reader"
        XCTAssertTrue(s.setupRequired)                 // pass 仍空
        s.remotePass = "pw"
        XCTAssertFalse(s.setupRequired)
        s.dbSrc = "local"
        XCTAssertTrue(s.setupRequired)                 // localUser 空
        s.localUser = "root"
        XCTAssertFalse(s.setupRequired)                // local 只看 user
    }

    // MARK: - normalizePer（02_q_db §0.1：档位 20/40/60/80/100，边界）

    /// 合法档位原样；v<=0 用 default；最近档含并列取第一个最小（30→20、50→40、70→60）
    func test_normalizePer_boundaries() {
        XCTAssertEqual(normalizePer(20), 20)
        XCTAssertEqual(normalizePer(40), 40)
        XCTAssertEqual(normalizePer(60), 60)
        XCTAssertEqual(normalizePer(80), 80)
        XCTAssertEqual(normalizePer(100), 100)
        // v<=0 → default（默认 40）
        XCTAssertEqual(normalizePer(0), 40)
        XCTAssertEqual(normalizePer(-5), 40)
        XCTAssertEqual(normalizePer(0, default: 60), 60)
        // 最近档
        XCTAssertEqual(normalizePer(19), 20)
        XCTAssertEqual(normalizePer(21), 20)
        XCTAssertEqual(normalizePer(31), 40)
        XCTAssertEqual(normalizePer(49), 40)
        XCTAssertEqual(normalizePer(55), 60)
        XCTAssertEqual(normalizePer(90), 80)
        XCTAssertEqual(normalizePer(101), 100)
        XCTAssertEqual(normalizePer(999), 100)
        // 并列取第一个最小：30 → 20/40 距离同为 10 → 20；50 → 40/60 → 40；70 → 60/80 → 60
        XCTAssertEqual(normalizePer(30), 20)
        XCTAssertEqual(normalizePer(50), 40)
        XCTAssertEqual(normalizePer(70), 60)
    }
}
