import XCTest
@testable import JDLV
import JDLVCore

//
//  SettingsUITests.swift —— P12 设置项持久化逻辑测试（docs/_extract/11_settings.md、
//  13_theme_prefs_models.md §B、14_vm_tests A.1 的 iOS 等价）。
//
//  覆盖：
//  - 键写入/读取往返（UserDefaults spy，隔离 suite；口令绝不进 UserDefaults）
//  - 读取归一化钳制（query_timeout→8 / home_per→24 / 上限旧哨兵→0 / view_mode 旧 big 迁移 /
//    proxy_cdn 旧键迁移）
//  - 保存三态文案生成（SAVED/NO_CHANGE/FAILED/编辑中）
//  - changesBetween 判定（15/8/2/4 分组样例；jdb_sort_asc 不入 dbChanged）
//  - 测试连接文案生成（成功模板/5 层异常链 " ← "/500 截断/提示表 5 条逐字）
//  - 图床自检四条结果行格式化（§4.1 模板）
//  - 离线上限解析与格式化（LimitMath parse/format/isValid）
//  - applyIndexLimit 五种 Toast / 继续索引 Toast 映射
//  - LockSetup.needsConfirmation（P6 接口）
//  - 摘要规则与预估体积文案
//  - editChain 800ms 防抖合并（跨字段快速输入不丢字段）+ autoSave 三态
//  - 折叠记忆键 CollapsiblePref
//  - 快照注入 CdnRewrite.settingsProvider（TestImages.enabled / jdbImgUrl / applyHostOnly）
//

final class SettingsUITests: XCTestCase {

    // MARK: - 工具（隔离 UserDefaults suite）

    private static var wipedTags: Set<String> = []

    private func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "test_settings_\(tag)"
        // 仅首个使用者清域（同 suite 二次获取要保留刚写入的数据 —— roundtrip 用例依赖）
        if !Self.wipedTags.contains(tag) {
            UserDefaults().removePersistentDomain(forName: name)
            Self.wipedTags.insert(tag)
        }
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    private func makeStore(_ tag: String) -> SettingsStore {
        SettingsStore(defaults: freshDefaults(tag))
    }

    /// 直接向 defaults 写一份存储 JSON（模拟旧版本落盘数据）
    private func seed(_ defaults: UserDefaults, _ dict: [String: Any]) {
        let data = AppSettings.encodeStorageJSON(dict)!
        defaults.set(data, forKey: AppSettings.storageDefaultsKey)
    }

    override func tearDown() {
        super.tearDown()
        // 恢复 CdnRewrite 默认 provider，避免污染其它用例
        CdnRewrite.settingsProvider = { CdnSettings() }
    }

    // MARK: 1. 键写入/读取往返

    @MainActor
    func testStoreRoundTripPersistsKeyGroups() async {
        let store = makeStore("roundtrip")
        let r = await store.updateSettingsNow { s in
            s.dbSrc = "local"
            s.remoteHost = "10.0.0.9"
            s.remotePort = "3308"
            s.remoteJdb = "jdb2"
            s.perPage = 60
            s.homeTtl = 5
            s.filterTtl = 0
            s.viewMode = 2
            s.coverHalf = 1
            s.dbSsl = false
            s.shadowTagIndex = false
            s.themeAccent = "青"
            s.shtPer = 80
        }
        XCTAssertEqual(r, .saved)

        // 新实例（同 suite）读回 —— DataStore 单键 JSON 对位
        let d = freshDefaults("roundtrip")
        let store2 = SettingsStore(defaults: d)
        let s2 = store2.settings
        XCTAssertEqual(s2.dbSrc, "local")
        XCTAssertEqual(s2.remoteHost, "10.0.0.9")
        XCTAssertEqual(s2.remotePort, "3308")
        XCTAssertEqual(s2.remoteJdb, "jdb2")
        XCTAssertEqual(s2.perPage, 60)
        XCTAssertEqual(s2.homeTtl, 5)
        XCTAssertEqual(s2.filterTtl, 0)
        XCTAssertEqual(s2.viewMode, 2)
        XCTAssertEqual(s2.coverHalf, 1)
        XCTAssertEqual(s2.dbSsl, false)
        XCTAssertEqual(s2.shadowTagIndex, false)
        XCTAssertEqual(s2.themeAccent, "青")
        XCTAssertEqual(s2.shtPer, 80)
    }

    // MARK: 2. 口令绝不落 UserDefaults（B.7 不变量）

    @MainActor
    func testSecretsNeverWrittenToDefaults() async {
        let defaults = freshDefaults("secrets")
        let store = SettingsStore(defaults: defaults)
        _ = await store.updateSettingsNow { s in
            s.remoteHost = "h1"
            s.remotePass = "p@ss明文"
            s.localPass = "本地明文"
        }
        guard let data = defaults.data(forKey: AppSettings.storageDefaultsKey) else {
            return XCTFail("storage JSON missing")
        }
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("remote_pass"), "remote_pass 键不得进 UserDefaults")
        XCTAssertFalse(json.contains("local_pass"), "local_pass 键不得进 UserDefaults")
        XCTAssertFalse(json.contains("lock_secret"), "lock_secret 键不得进 UserDefaults")
        XCTAssertFalse(json.contains("p@ss明文"), "口令明文不得进 UserDefaults")
        // 新实例读回：口令为空（无 Keychain 注入路径时不回读明文）
        let store2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(store2.settings.remoteHost, "h1")
    }

    // MARK: 3-5. 读取归一化钳制（B.5）

    @MainActor
    func testQueryTimeoutClampNormalizedTo8() {
        let defaults = freshDefaults("clamp_qt")
        seed(defaults, ["query_timeout": 20])
        let s = AppSettings.fromStorageJSON(defaults.data(forKey: AppSettings.storageDefaultsKey)!)
        XCTAssertEqual(s.queryTimeout, 8, "档位外旧值 (20/60) 读取归一为 8")
    }

    @MainActor
    func testHomePerClampNormalizedTo24() {
        let defaults = freshDefaults("clamp_hp")
        seed(defaults, ["home_per": 30])
        let s = AppSettings.fromStorageJSON(defaults.data(forKey: AppSettings.storageDefaultsKey)!)
        XCTAssertEqual(s.homePer, 24, "档位外旧值读取归一为 24")
    }

    @MainActor
    func testShadowLimitSentinelNormalizedToZero() {
        let defaults = freshDefaults("clamp_limit")
        seed(defaults, ["shadow_limit_jdb": Int(Int32.max / 2), "shadow_limit_sht": Int32.max])
        let s = AppSettings.fromStorageJSON(defaults.data(forKey: AppSettings.storageDefaultsKey)!)
        XCTAssertEqual(s.shadowLimitJdb, 0, "旧哨兵 Int.max/2 归一为 0=不限")
        XCTAssertEqual(s.shadowLimitSht, 0)
    }

    @MainActor
    func testViewModeAndProxyCdnLegacyMigration() {
        let defaults = freshDefaults("migrate")
        seed(defaults, ["big": true, "proxy_cdn": true])
        let s = AppSettings.fromStorageJSON(defaults.data(forKey: AppSettings.storageDefaultsKey)!)
        XCTAssertEqual(s.viewMode, 1, "view_mode 未落盘时按旧 big=true 换算 1=大图")
        XCTAssertEqual(s.proxyCdnJdb, true, "proxy_cdn_jdb 未落盘沿用旧 proxy_cdn")
        XCTAssertEqual(s.proxyCdnSht, true)
    }

    // MARK: 6. 保存三态文案生成（§0.1 逐字）

    @MainActor
    func testSaveStateTextThreeStates() {
        XCTAssertEqual(SettingsCopy.saveStateText(kind: 0, at: Date()), "保存中…")
        XCTAssertEqual(SettingsCopy.saveStateText(kind: 2, at: Date()), "无变化")
        XCTAssertEqual(SettingsCopy.saveStateText(kind: 3, at: Date()), "保存失败 (重试或检查存储)")
        let saved = SettingsCopy.saveStateText(kind: 1, at: Date())
        XCTAssertTrue(saved.hasPrefix("已保存 "), "SAVED 文案 = 已保存 HH:mm:ss")
        XCTAssertEqual(saved.count, "已保存 ".count + 8, "HH:mm:ss 共 8 字符")
        let re = try! NSRegularExpression(pattern: "^已保存 \\d{2}:\\d{2}:\\d{2}$")
        let range = NSRange(saved.startIndex..., in: saved)
        XCTAssertNotNil(re.firstMatch(in: saved, range: range))
    }

    // MARK: 7-9. changesBetween 判定（15/8/2/4 分组）

    @MainActor
    func testChangesBetweenDbCategory() {
        let store = makeStore("changes")
        var n = store.settings
        n.remoteHost = "1.2.3.4"
        let e = store.changesBetween(store.settings, n)
        XCTAssertTrue(e.db, "remote_host ∈ dbChanged 15 字段")
        XCTAssertFalse(e.cdn)
        XCTAssertFalse(e.img)
        XCTAssertFalse(e.proxy)

        // 其余 db 字段样例：db_src / db_ssl / query_timeout / local_user / remote_pass / remote_sht
        let dbMutations: [(String, (inout AppSettings) -> Void)] = [
            ("db_src", { $0.dbSrc = "local" }),
            ("db_ssl", { $0.dbSsl = false }),
            ("query_timeout", { $0.queryTimeout = 15 }),
            ("local_user", { $0.localUser = "u" }),
            ("remote_pass", { $0.remotePass = "p" }),
            ("remote_sht", { $0.remoteSht = "sht2" }),
        ]
        for (name, mutate) in dbMutations {
            var m = store.settings
            mutate(&m)
            let e2 = store.changesBetween(store.settings, m)
            XCTAssertTrue(e2.db, "\(name) 应命中 dbChanged")
            XCTAssertFalse(e2.cdn); XCTAssertFalse(e2.img); XCTAssertFalse(e2.proxy)
        }

        // jdb_sort_asc 不纳入 dbChanged（S11-P2）
        var m = store.settings
        m.jdbSortAsc = !m.jdbSortAsc
        let e3 = store.changesBetween(store.settings, m)
        XCTAssertFalse(e3.db, "jdb_sort_asc 不触发 Db.reset")
        XCTAssertTrue(e3.none)
    }

    @MainActor
    func testChangesBetweenCdnCategory() {
        let store = makeStore("changes_cdn")
        // cdnChanged 8：proxy_host/port + proxy_cdn(+jdb/sht) + jdb_img_host + sht_mirror(+host)
        for mutate in [{ (s: inout AppSettings) in s.proxyHost = "9.9.9.9" },
                       { (s: inout AppSettings) in s.proxyPort = "7891" },
                       { (s: inout AppSettings) in s.proxyCdn = true },
                       { (s: inout AppSettings) in s.proxyCdnJdb = true },
                       { (s: inout AppSettings) in s.proxyCdnSht = true },
                       { (s: inout AppSettings) in s.jdbImgHost = "web" },
                       { (s: inout AppSettings) in s.shtMirror = "https://x.example" },
                       { (s: inout AppSettings) in s.shtMirrorHost = "x.example" }] {
            var m = store.settings
            mutate(&m)
            let e = store.changesBetween(store.settings, m)
            XCTAssertTrue(e.cdn, "cdn 分组样例未命中")
            XCTAssertFalse(e.db, "cdn 字段不得触发 dbChanged")
        }
        // 纯展示字段不触发任何副作用
        var m = store.settings
        m.themeName = "light"
        XCTAssertTrue(store.changesBetween(store.settings, m).none)
    }

    @MainActor
    func testChangesBetweenImgAndProxyCategories() {
        let store = makeStore("changes_img")
        var m = store.settings
        m.imageCacheMb = 256
        let e = store.changesBetween(store.settings, m)
        XCTAssertTrue(e.img, "image_cache_mb ∈ imgChanged 2 字段")
        XCTAssertFalse(e.db); XCTAssertFalse(e.cdn); XCTAssertFalse(e.proxy)

        var m2 = store.settings
        m2.imageCacheDays = 7
        XCTAssertTrue(store.changesBetween(store.settings, m2).img)

        var m3 = store.settings
        m3.proxyDb = true
        let e3 = store.changesBetween(store.settings, m3)
        XCTAssertTrue(e3.proxy, "proxy_db ∈ proxyChanged 4 字段")
        XCTAssertFalse(e3.db); XCTAssertFalse(e3.cdn); XCTAssertFalse(e3.img)
    }

    // MARK: 10. 测试连接文案生成（§13）

    func testTestConnSuccessText() {
        XCTAssertEqual(SettingsDiagnostics.formatSuccess(elapsedMs: 123, versions: ["8.0.36"]),
                       "✓ 两库均连接成功 · 123 ms · 8.0.36")
        XCTAssertEqual(SettingsDiagnostics.formatSuccess(elapsedMs: 5, versions: []),
                       "✓ 两库均连接成功 · 5 ms · ?")
    }

    func testTestConnChainAndHintTable() {
        // 层模板：simpleName: message(截 140)
        let layer = SettingsDiagnostics.layerOf(DbError(kind: .connection, message: "boom"))
        XCTAssertTrue(layer.hasPrefix("DbError: boom"))

        // 5 层 " ← " 拼接；第 6 层丢弃
        let layers = (1...6).map { "E\($0): m\($0)" }
        let chain = SettingsDiagnostics.chainText(layers)
        XCTAssertEqual(chain, "E1: m1 ← E2: m2 ← E3: m3 ← E4: m4 ← E5: m5")

        // 500 字截断
        let long = SettingsDiagnostics.chainText([String(repeating: "x", count: 900)])
        XCTAssertEqual(long.count, 500)

        // 空 → 连接失败
        XCTAssertEqual(SettingsDiagnostics.chainText([]), "连接失败")

        // 提示直接追加（无换行分隔）
        let f = SettingsDiagnostics.formatFailure(layers: ["E: Communications link failure"],
                                                  hint: SettingsDiagnostics.hintFor("E: Communications link failure"))
        XCTAssertEqual(f, "✗ E: Communications link failure提示: 手机与服务器需在同一局域网 (或在上方开启数据库代理), 并确认服务器防火墙放行该端口")

        // 提示表 5 条逐字
        XCTAssertEqual(SettingsDiagnostics.hintFor("...Access denied..."), "用户名或密码错误")
        XCTAssertEqual(SettingsDiagnostics.hintFor("Unknown database 'x'"), "库名不存在 (检查 javdb / sehuatang 库名)")
        XCTAssertEqual(SettingsDiagnostics.hintFor("caching_sha2_password"), "账号认证插件不兼容, 在服务器上为账号改用 mysql_native_password")
        XCTAssertEqual(SettingsDiagnostics.hintFor("Unable to resolve host \"h\""), "主机名无法解析 (检查 IP/端口)")
        XCTAssertNil(SettingsDiagnostics.hintFor("其它错误"))
    }

    // MARK: 11. 图床自检四条结果行（§4.1 模板）

    func testSelfTestLineFormats() {
        // 成功（jdb 类：label 解码、kb 格式）
        var l = SettingsDiagnostics.selfTestLine(kind: "app", code: 200, bytes: 46_080,
                                                 decoded: true, ms: 88, err: "")
        XCTAssertEqual(l.text, "app 200 · 45KB · 解码OK · 88ms")
        XCTAssertTrue(l.ok); XCTAssertFalse(l.failed)

        // 解码失败 → ✗ + tertiary（非红）
        l = SettingsDiagnostics.selfTestLine(kind: "web", code: 200, bytes: 500,
                                             decoded: false, ms: 10, err: "")
        XCTAssertEqual(l.text, "web 200 · 500B · 解码✗ · 10ms")
        XCTAssertFalse(l.ok)

        // sht/ext 类 label 图片、ok 需 code==200
        l = SettingsDiagnostics.selfTestLine(kind: "sht", code: 200, bytes: 2048,
                                             decoded: true, ms: 33, err: "")
        XCTAssertEqual(l.text, "sht 200 · 2KB · 图片OK · 33ms")
        l = SettingsDiagnostics.selfTestLine(kind: "ext", code: 403, bytes: 100,
                                             decoded: true, ms: 21, err: "")
        XCTAssertEqual(l.text, "ext 403 · 100B · 图片✗ · 21ms")
        XCTAssertFalse(l.ok)

        // 有 err → code=ERR / 原样 code
        l = SettingsDiagnostics.selfTestLine(kind: "sht", code: 0, bytes: 0,
                                             decoded: false, ms: 0, err: "无样例")
        XCTAssertEqual(l.text, "sht code=ERR · 无样例")
        XCTAssertTrue(l.failed)
        l = SettingsDiagnostics.selfTestLine(kind: "app", code: 0, bytes: 0,
                                             decoded: false, ms: 0, err: "库内暂无样例")
        XCTAssertEqual(l.text, "app · 库内暂无样例")
    }

    // MARK: 12. 离线上限解析与格式化（LimitMath）

    func testLimitMathParseAndFormat() {
        XCTAssertEqual(LimitMath.parseWan("12.5"), 125_000)
        XCTAssertEqual(LimitMath.parseWan("24"), 240_000)
        XCTAssertNil(LimitMath.parseWan("abc"))
        XCTAssertNil(LimitMath.parseWan(""))
        XCTAssertNil(LimitMath.parseCount("-1"))
        XCTAssertEqual(LimitMath.parseCount("125000"), 125_000)
        XCTAssertFalse(LimitMath.isValid(nil))
        XCTAssertFalse(LimitMath.isValid(5_000_001))
        XCTAssertTrue(LimitMath.isValid(0))
        XCTAssertTrue(LimitMath.isValid(5_000_000))

        XCTAssertEqual(LimitMath.format(0), "不限")
        XCTAssertEqual(LimitMath.format(80_000), "8 万 (80,000)")
        XCTAssertEqual(LimitMath.format(125_000), "12.5 万 (125,000)")
        XCTAssertEqual(LimitMath.format(9_999), "9,999 条")
        XCTAssertEqual(LimitMath.normalizeStored(Int(Int32.max / 2)), 0)
        XCTAssertEqual(LimitMath.targetOf(0), Int64.max / 2)
    }

    // MARK: 13. 上限对话框文案（§11.8 逐字）

    func testIndexLimitDialogTexts() {
        XCTAssertEqual(SettingsCopy.limitEstText(n: nil), "输入条数")
        XCTAssertEqual(SettingsCopy.limitEstText(n: 0), "不限 · 按实际行数 (全库约 136MB)")
        XCTAssertEqual(SettingsCopy.limitEstText(n: 1000), "预估 0.2 MB")
        XCTAssertEqual(SettingsCopy.limitInvalidText, "请输入 0 – 5,000,000 (0 = 不限)")
        XCTAssertEqual(SettingsCopy.limitTrimPreview(20_000), "改小将裁剪多余 20,000 条索引 (保留最新)")
        XCTAssertEqual(SettingsCopy.limitIndexedCount(1_234_567), "当前已索引 1,234,567")
        XCTAssertEqual(SettingsCopy.limitRealtimeLine(n: 0, est: "x", avail: "y"),
                       "= 不限 条 · x · y")
        XCTAssertEqual(SettingsCopy.trimConfirmBody(current: 100_000, keep: 80_000),
                       "将删除多余 20,000 条索引 (按发布日期从旧到新裁剪，保留最新 80,000 条), 不可恢复。")
    }

    // MARK: 14. applyIndexLimit 五种 Toast / 继续 Toast（§11.7/§11.9 逐字）

    func testApplyLimitToastBranches() {
        XCTAssertEqual(SettingsDiagnostics.applyLimitToast(result: .NO_CHANGE, wasRunning: false, offline: false),
                       "上限未变化，已继续索引")
        XCTAssertEqual(SettingsDiagnostics.applyLimitToast(result: .NO_CHANGE, wasRunning: true, offline: false),
                       "上限未变化")
        XCTAssertEqual(SettingsDiagnostics.applyLimitToast(result: .STARTED, wasRunning: false, offline: true),
                       "已保存；当前离线，联网后自动续跑")
        XCTAssertEqual(SettingsDiagnostics.applyLimitToast(result: .STARTED, wasRunning: false, offline: false),
                       "✓ 上限已更新，正在按新上限收敛")
        XCTAssertEqual(SettingsDiagnostics.applyLimitToast(result: .DISABLED, wasRunning: false, offline: false),
                       "上限未变化")

        XCTAssertEqual(SettingsDiagnostics.resumeToast(.ALREADY_RUNNING), "预热正在运行中")
        XCTAssertEqual(SettingsDiagnostics.resumeToast(.DISABLED), "请先启用离线索引")
        XCTAssertEqual(SettingsDiagnostics.resumeToast(.STARTED), "✓ 继续索引已启动 (从断点续跑)")
    }

    // MARK: 15. LockSetup.needsConfirmation（P6 接口）

    func testLockSetupNeedsConfirmation() {
        XCTAssertFalse(LockSetup.needsConfirmation(currentEnabled: false, currentType: "none",
                                                   newEnabled: false, newType: "none"))
        XCTAssertTrue(LockSetup.needsConfirmation(currentEnabled: false, currentType: "none",
                                                  newEnabled: true, newType: "pin"))
        XCTAssertTrue(LockSetup.needsConfirmation(currentEnabled: true, currentType: "pin",
                                                  newEnabled: true, newType: "pattern"))
        XCTAssertTrue(LockSetup.needsConfirmation(currentEnabled: true, currentType: "pin",
                                                  newEnabled: false, newType: "none"))
        XCTAssertFalse(LockSetup.needsConfirmation(currentEnabled: true, currentType: "pin",
                                                   newEnabled: true, newType: "pin"))
    }

    // MARK: 16. 摘要规则 / 预估体积文案（§1/§11.2/§11.3）

    func testSummaryRules() {
        var s = AppSettings()
        s.remoteHost = "10.0.0.5"                    // R4：测试注入，不依赖任何预置 IP
        s.remotePort = "3306"
        XCTAssertEqual(SettingsCopy.summaryDb(s), "数据源 · remote · 10.0.0.5:3306")
        XCTAssertEqual(SettingsCopy.summaryProxy(s), "代理 · 数据库关 / jdb 图床关 / 98t 图床关")
        s.proxyDb = true
        XCTAssertEqual(SettingsCopy.summaryProxy(s), "代理 · 数据库开 / jdb 图床关 / 98t 图床关")
        XCTAssertEqual(SettingsCopy.summaryLock(s), "未启用")
        s.lockEnabled = true
        s.lockType = "pin"
        XCTAssertEqual(SettingsCopy.summaryLock(s), "已启用 · pin")
        XCTAssertEqual(SettingsCopy.summaryBrowse(s), "视图 0 · 每页 40 · 98t 每页 20")
        XCTAssertEqual(SettingsCopy.summaryCache(s), "图片缓存 128 MB · 过期 30 天")
        s.imageCacheDays = 0
        XCTAssertEqual(SettingsCopy.summaryCache(s), "图片缓存 128 MB · 过期 不过期")
        XCTAssertEqual(SettingsCopy.summaryShadow(s), "仅索引 · 影片 8 万 (80,000) / 帖子 15 万 (150,000) · 女优 开")
        s.shadowEnabled = false
        XCTAssertEqual(SettingsCopy.summaryShadow(s), "未启用")
        s.shadowLimitJdb = 0
        s.shadowEnabled = true
        XCTAssertEqual(SettingsCopy.summaryShadow(s), "仅索引 · 影片 不限 / 帖子 15 万 (150,000) · 女优 开")
        XCTAssertEqual(SettingsCopy.summaryShtImg(live: s, draft: s), "98t 图床 · 未嗅探")
        var live = s
        live.shtMirrorHost = "abc.example"
        XCTAssertEqual(SettingsCopy.summaryShtImg(live: live, draft: s), "98t 图床 · abc.example")
        XCTAssertEqual(SettingsCopy.summarySemantic(installed: false), "语义模型 · 未导入 (语义搜索已禁用)")
        XCTAssertEqual(SettingsCopy.summaryAbout, "JDLV Mobile · 远程库只读浏览客户端")
    }

    func testTagEstimateAndVolumeText() {
        // 80000 部 → 80000*5.7/1000*0.04 = 18.24 → "+18 MB"，不告警
        let e1 = SettingsCopy.tagEstimateText(limitJdb: 80_000)
        XCTAssertTrue(e1.text.hasPrefix("标签索引预估: +18 MB (实测约 5.7 标签/片 · 0.04MB/千行)"))
        XCTAssertFalse(e1.warn)
        // 0（不限）→ 全库 1,008,039 部 + ⚠
        let e2 = SettingsCopy.tagEstimateText(limitJdb: 0)
        XCTAssertTrue(e2.text.contains(" ⚠ 目标较大, 请确认设备空间"))
        XCTAssertTrue(e2.warn)

        // 预估体积（§11.3 拼接）
        let v1 = SettingsCopy.estimateText(limitJdb: 80_000, limitSht: 150_000, actorIndex: true)
        XCTAssertTrue(v1.hasPrefix("预估体积: 影片 16.8 MB + 帖子 31.5 MB ≈ 48.3 MB (0.21 MB/千条); "))
        XCTAssertTrue(v1.hasSuffix("女优约 19MB (91,745 人), 出演关系按已索引影片数约 4–40MB"))
        let v2 = SettingsCopy.estimateText(limitJdb: 0, limitSht: 0, actorIndex: false)
        XCTAssertTrue(v2.contains(" ≈ 按实际行数 (0.21 MB/千条); 全量索引(影片/帖子各约 136MB)另女优约 19MB + 出演关系 30–40MB, 合计约 320–400MB; "))
        XCTAssertTrue(v2.hasSuffix("女优/出演关系未启用"))
    }

    // MARK: 17. 进度区行文案（§11.6 逐字模板）

    func testProgressLineTexts() {
        XCTAssertEqual(SettingsCopy.etaText(0), "")
        XCTAssertEqual(SettingsCopy.etaText(45), "预计 45 秒")
        XCTAssertEqual(SettingsCopy.etaText(125), "预计 2 分 5 秒")
        XCTAssertEqual(SettingsCopy.roundLine(phase: "", speed: 320, eta: "预计 45 秒", note: "预热中…"),
                       "本轮: idle · 320 条/分 预计 45 秒 · 预热中…")
        XCTAssertEqual(SettingsCopy.roundLine(phase: "threads", speed: 0, eta: "", note: "空闲"),
                       "本轮: threads · 0 条/分  · 空闲")
        let line = SettingsCopy.indexedLine(movies: 12_345, threads: 678, actors: 9,
                                            actorTotal: 91_745, limitJdb: 80_000, limitSht: 0)
        XCTAssertEqual(line, "已索引: 影片 12,345 / 8 万 (80,000) · 帖子 678 / 不限 · 女优 9 / 91,745")
        let line2 = SettingsCopy.indexedLine(movies: 999, threads: 0, actors: 0,
                                             actorTotal: 0, limitJdb: 80_000, limitSht: 0)
        XCTAssertTrue(line2.hasSuffix("女优 0 / —  (本地检索暂未启用)"))
    }

    // MARK: 18. editChain 800ms 防抖合并（S14-P1 B01/R3）

    @MainActor
    func testEditChainMergesRapidEdits() async throws {
        let store = makeStore("chain")
        store.edit { $0.remoteHost = "10.1.1.1" }
        store.edit { $0.remotePort = "3308" }
        store.edit { $0.remoteUser = "abc" }
        // 防抖窗口内未落盘（内存仍是默认空主机，与 AppSettings() 默认一致）
        XCTAssertEqual(store.settings.remoteHost, AppSettings().remoteHost)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(store.settings.remoteHost, "10.1.1.1", "主机")
        XCTAssertEqual(store.settings.remotePort, "3308", "端口（跨字段不丢）")
        XCTAssertEqual(store.settings.remoteUser, "abc", "用户")
        XCTAssertEqual(store.lastSaveResult, .saved)
    }

    // MARK: 19. autoSave 三态 / updateSettings 轻量通道

    @MainActor
    func testAutoSaveThreeStatesAndUpdateSettingsLight() async {
        let store = makeStore("threestates")
        // NO_CHANGE：值全等
        let r1 = await store.autoSave { _ in }
        XCTAssertEqual(r1, .noChange)
        XCTAssertEqual(store.lastSaveResult, .noChange)
        // SAVED
        let r2 = await store.autoSave { $0.themeName = "light" }
        XCTAssertEqual(r2, .saved)
        XCTAssertEqual(store.settings.themeName, "light")
        // 轻量通道（不写 lastSaveResult，纯展示设置用）
        store.updateSettings { $0.semThreshold = 20 }
        XCTAssertEqual(store.settings.semThreshold, 20)
        // editNow：合并未触发链 + 立即落盘
        store.edit { $0.remoteHost = "10.2.2.2" }
        let r3 = await store.editNow { $0.proxyDb = true }
        XCTAssertEqual(r3, .saved)
        XCTAssertEqual(store.settings.remoteHost, "10.2.2.2", "editNow 需带上未落盘的链")
        XCTAssertEqual(store.settings.proxyDb, true)
    }

    // MARK: 20. 折叠记忆键

    func testCollapsiblePrefRemember() {
        let d = freshDefaults("fold")
        let k = "db"
        XCTAssertFalse(CollapsiblePref.isExpanded(k, default: false, defaults: d))
        XCTAssertTrue(CollapsiblePref.isExpanded(k, default: true, defaults: d))
        CollapsiblePref.setExpanded(k, value: true, defaults: d)
        XCTAssertTrue(CollapsiblePref.isExpanded(k, default: false, defaults: d))
        XCTAssertEqual(CollapsiblePref.key(k), "settings_fold_db")
    }

    // MARK: 21. 快照注入 CdnRewrite.settingsProvider

    func testCdnSettingsProviderInjection() {
        let box = SettingsSnapshotBox()
        var s = AppSettings()
        s.testImgMode = true
        s.jdbImgHost = "https://mirror.example.com"
        s.shtMirrorHost = "sniff.example"
        s.coverHalf = 1
        box.update(s)
        CdnRewrite.settingsProvider = { box.cdnSettings }

        // 快照逐字段映射
        let snap = CdnRewrite.settings()
        XCTAssertTrue(snap.testImgMode)
        XCTAssertEqual(snap.jdbImgHost, "https://mirror.example.com")
        XCTAssertEqual(snap.shtMirrorHost, "sniff.example")
        XCTAssertEqual(snap.coverHalf, 1)

        // 图片管线消费路径（DEBUG 构建下 TestImages.enabled 读 provider）
        #if DEBUG
        XCTAssertTrue(TestImages.enabled(), "testImgMode 经 settingsProvider 生效")
        #endif
        // jdb 图床 URL 重建走 provider 的自定义镜像
        let url = CdnRewrite.jdbImgUrl("/covers/z4/z49rR4.jpg")   // Img.movieCover 回退形态（前导 /）
        XCTAssertTrue(url.contains("mirror.example.com"), "自定义镜像经 provider 注入生效: \(url)")

        // applyHostOnly：嗅探 host → 内存 shtHost
        CdnRewrite.applyHostOnly()
        XCTAssertEqual(CdnRewrite.shtHost, "sniff.example")
    }

    // MARK: 22. 98t 嗅探静默规则（normalize 空 → 不动作）

    @MainActor
    func testSnifferRequestRejectsBlankUrl() {
        let sniffer = CdnSniffer.shared
        sniffer.cancel()   // 清理可能在跑的任务
        let started = sniffer.request(kind: "sht", siteUrl: "  ")
        XCTAssertFalse(started, "normalize 后空串 → 静默不动作")
        XCTAssertFalse(sniffer.state.running)
    }
}
