//
//  SettingsDiagnostics.swift
//  JDLV
//
//  P12：设置页诊断与副作用接线（docs/_extract/11_settings.md §13/§4/§5/§10/§11）。
//
//  职责（只调用 JDLVCore 公开 API 与 Services 只读入口，不改它们内部）：
//  - 测试连接 testConnection（① 数据源 与 ② 代理共用）：两库各建连一次
//    （SELECT VERSION() 的 Db.check 语义 —— 生产走 MySQLPool.ping）；connLock 串行
//    （actor，测试期间并发查询不会串代理）；结果文案逐字 + 5 层异常链 " ← " 拼接
//    + 提示表直接追加。
//  - demo 模式（-JDLV_DEMO 1）：全部诊断按钮返回假结果（"演示模式"标注）。
//  - 图床自检四条结果行格式化（CdnSelfTest.run 逐字模板）。
//  - 查询缓存清理 / 过期图片清扫（ImagePipeline 磁盘目录 Caches/jdlv_img 同路径实现，
//    ImagePipeline 内部不可改）。
//  - SettingsEffects：autoSave 副作用执行器（MainVm autoSave 锁外单消费者对位）——
//    dbChanged → Db.reset()（内含 invalidateSchema）+ bumpData；
//    cdnChanged → CdnRewrite.invalidate() + applyHostOnly() + bumpData；
//    imgChanged → TestImages.clearCache()（rebuildImageLoader 对位：下次加载按新设置）；
//    proxyChanged → SocksTunnel 重建留注释（本阶段不建隧道，测试连接直连）。
//  - SettingsSnapshotBox：线程安全 AppSettings 快照（CdnRewrite.settingsProvider 注入 ——
//    provider 会被图片管线在任意线程读取，不能直接走 @MainActor SettingsStore）。
//  - SettingsIndexHub：懒建 IdxDb + SyncCoordinator + EmbStore（Application Support），
//    供离线索引卡与语义卡只读调用（P13 页面接线会复用同一目录布局）。
//

import Foundation
import JDLVCore

// MARK: - 测试连接 / 图床自检 / 缓存清理

enum SettingsDiagnostics {

    private init() {}

    // MARK: demo 模式

    /// `-JDLV_DEMO 1` 启用（与 DemoDataSource 同判定）
    static var isDemo: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-JDLV_DEMO"), i + 1 < args.count else { return false }
        return args[i + 1] == "1"
    }

    // MARK: 测试连接（§13；① 与 ② 共用）

    /// 测试期间并发查询不串代理的串行门（Android connLock 对位）
    private static let connGate = ConnTestGate()

    /// 测试连接入口。生产环境 Db 未配置时 ping 失败 → "远程库不可达：…" 原样展示。
    static func testConnection(_ s: AppSettings) async -> String {
        if isDemo {
            // demo：假结果 + 演示模式标注
            return "✓ 两库均连接成功 · 12 ms · 8.0.36（演示模式）"
        }
        return await connGate.run(s)
    }

    /// 成功文案（逐字模板）：`✓ 两库均连接成功 · ${耗时 ms} ms · ${versions.firstOrNull() ?: "?"}`
    static func formatSuccess(elapsedMs: Int64, versions: [String]) -> String {
        "✓ 两库均连接成功 · \(elapsedMs) ms · \(versions.first ?? "?")"
    }

    /// 单层异常文案（逐字模板）：`${simpleName}: ${message?.take(140) ?: ""}`
    static func layerOf(_ error: Error) -> String {
        let name = String(describing: type(of: error))
        let msg = (error as? CustomStringConvertible)?.description ?? String(describing: error)
        return "\(name): \(String(msg.prefix(140)))"
    }

    /// 异常链拼接：最多 5 层、以 " ← " 连接、截 500 字、空则 "连接失败"
    static func chainText(_ layers: [String]) -> String {
        let joined = layers.prefix(5).joined(separator: " ← ")
        if joined.isEmpty { return "连接失败" }
        return String(joined.prefix(500))
    }

    /// 失败文案：`✗ ${chain}` + (命中提示时直接追加, 无换行分隔) `提示: $hint`
    static func formatFailure(layers: [String], hint: String?) -> String {
        var text = "✗ \(chainText(layers))"
        if let h = hint { text += "提示: \(h)" }
        return text
    }

    /// 提示表（逐字 5 条）
    static func hintFor(_ message: String) -> String? {
        if message.contains("Communications link failure") {
            return "手机与服务器需在同一局域网 (或在上方开启数据库代理), 并确认服务器防火墙放行该端口"
        }
        if message.contains("Access denied") {
            return "用户名或密码错误"
        }
        if message.contains("Unknown database") {
            return "库名不存在 (检查 javdb / sehuatang 库名)"
        }
        if message.contains("caching_sha2") {
            return "账号认证插件不兼容, 在服务器上为账号改用 mysql_native_password"
        }
        if message.contains("Unable to resolve host") {
            return "主机名无法解析 (检查 IP/端口)"
        }
        return nil
    }

    // MARK: 图床自检（§4.1 四条结果行）

    struct SelfTestLine: Equatable {
        var text: String
        var ok: Bool        // primary 绿
        var failed: Bool    // error 红（有 err）；否则 tertiary
    }

    /// 单条结果行格式化（逐字模板；kind: app/web/sht/ext）
    static func selfTestLine(kind: String, code: Int, bytes: Int,
                             decoded: Bool, ms: Int64, err: String) -> SelfTestLine {
        if err == "库内暂无样例" {
            return SelfTestLine(text: "\(kind) · 库内暂无样例", ok: false, failed: true)
        }
        let isJdb = kind == "app" || kind == "web"
        let label = isJdb ? "解码" : "图片"
        let ok = err.isEmpty && (isJdb ? decoded : decoded && code == 200)
        if err.isEmpty {
            let kb = bytes >= 1024 ? "\(bytes / 1024)KB" : "\(bytes)B"
            return SelfTestLine(text: "\(kind) \(code) · \(kb) · \(label)\(ok ? "OK" : "✗") · \(ms)ms",
                                ok: ok, failed: false)
        }
        let codeText = code == 0 ? "ERR" : "\(code)"
        return SelfTestLine(text: "\(kind) code=\(codeText) · \(err)", ok: false, failed: true)
    }

    /// 运行自检（IO 内 CdnSelfTest.run 四类各 1 条, 单条失败不拖垮其它类）；
    /// demo 模式返回四条假结果（"演示模式"标注）。
    static func runSelfTest() async -> [SelfTestLine] {
        if isDemo {
            let demo = { (kind: String, label: String) -> SelfTestLine in
                SelfTestLine(text: "\(kind) 200 · 45KB · \(label)OK · 88ms（演示模式）",
                             ok: true, failed: false)
            }
            return [demo("app", "解码"), demo("web", "解码"), demo("sht", "图片"), demo("ext", "图片")]
        }
        let results = await CdnSelfTest.run()
        return results.map {
            selfTestLine(kind: $0.kind, code: $0.code, bytes: $0.bytes,
                         decoded: $0.decoded, ms: $0.ms, err: $0.err)
        }
    }

    // MARK: 缓存清理（§10 两按钮）

    /// `清理查询缓存`：QCache.clearDisk 对位 —— PageCache 磁盘文件删除
    /// （Application Support/page_cache.db，与 PageCache.DB_NAME 同名同目录布局）
    @discardableResult
    static func clearQueryCache() -> Bool {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = base else { return false }
        var any = false
        for suffix in ["", "-wal", "-shm"] {
            let p = dir.appendingPathComponent("page_cache.db" + suffix)
            if fm.fileExists(atPath: p.path) {
                try? fm.removeItem(at: p)
                any = true
            }
        }
        return any
    }

    /// `清理过期图片`：JdlvApp.sweepImageCache 对位 —— 扫 ImagePipeline 磁盘目录
    /// （Caches/jdlv_img，与 cacheDir 同路径；内部 private 不可复用），按修改时间删除过期文件。
    static func sweepImageCache(days: Int) -> Int {
        guard days > 0 else { return 0 }   // 0 = 不过期
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = caches.appendingPathComponent("jdlv_img", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        let deadline = Date().addingTimeInterval(-Double(days) * 86_400)
        var n = 0
        for item in items {
            guard let attrs = try? fm.attributesOfItem(atPath: item.path),
                  let mod = attrs[.modificationDate] as? Date, mod < deadline else { continue }
            if (try? fm.removeItem(at: item)) != nil { n += 1 }
        }
        return n
    }

    // MARK: 离线索引 Toast 文案（§11.7 / §11.9 逐字）

    /// 继续索引按钮 → sync.resume() 的 Toast
    static func resumeToast(_ r: StartResult) -> String {
        switch r {
        case .ALREADY_RUNNING: return "预热正在运行中"
        case .DISABLED: return "请先启用离线索引"
        default: return "✓ 继续索引已启动 (从断点续跑)"
        }
    }

    /// applyIndexLimit 的 Toast（五种分支：NO_CHANGE±running / STARTED±offline / 其它）
    static func applyLimitToast(result: StartResult, wasRunning: Bool, offline: Bool) -> String {
        switch result {
        case .STARTED:
            return offline ? "已保存；当前离线，联网后自动续跑" : "✓ 上限已更新，正在按新上限收敛"
        case .NO_CHANGE:
            return wasRunning ? "上限未变化" : "上限未变化，已继续索引"
        default:
            return "上限未变化"
        }
    }
}

// MARK: - 测试连接串行门（actor）

private actor ConnTestGate {

    func run(_ s: AppSettings) async -> String {
        let t0 = Perf.nowMs()
        var failed: String? = nil
        // 两库各建连一次（SELECT VERSION() 的 Db.check 语义 —— 生产走 MySQLPool.ping）。
        // 注：proxyDb 时 Android 包 DbPool.withSocks；iOS Socks5Tunnel 接线留 P13
        // （本阶段测试连接直连, 不建隧道；connGate 串行保证与并发查询互不穿插）。
        for which in ["jdb", "sht"] {
            if await Db.check(which) == false {
                failed = which
                break
            }
        }
        if let which = failed {
            let host = s.host
            let port = s.port
            let layer = "远程库不可达：无法连接 \(host):\(port)（\(which == "jdb" ? s.jdbDb : s.shtDb)）"
            return SettingsDiagnostics.formatFailure(layers: [layer],
                                                     hint: SettingsDiagnostics.hintFor(layer))
        }
        return SettingsDiagnostics.formatSuccess(elapsedMs: Perf.nowMs() - t0, versions: [])
    }
}

// MARK: - 线程安全设置快照（CdnRewrite.settingsProvider 注入）

/// provider 会被图片管线/熔断器在任意线程读取；SettingsStore 是 @MainActor 不能直接暴露，
/// 这里以锁保护的最小快照盒中转（设置页 onAppear/每次变更时刷新）。
final class SettingsSnapshotBox: @unchecked Sendable {

    private let lock = NSLock()
    private var _settings = AppSettings()

    func update(_ s: AppSettings) {
        lock.lock()
        _settings = s
        lock.unlock()
    }

    var settings: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return _settings
    }

    /// CdnSettings 快照（字段一一对应）
    var cdnSettings: CdnSettings {
        let s = settings
        return CdnSettings(
            jdbImgHost: s.jdbImgHost,
            shtMirror: s.shtMirror,
            shtMirrorHost: s.shtMirrorHost,
            proxyHost: s.proxyHost,
            proxyPort: s.proxyPort,
            proxyCdnJdb: s.proxyCdnJdb,
            proxyCdnSht: s.proxyCdnSht,
            imageCacheMb: s.imageCacheMb,
            imageCacheDays: s.imageCacheDays,
            coverHalf: s.coverHalf,
            testImgMode: s.testImgMode)
    }
}

// MARK: - autoSave 副作用执行器（MainVm 锁外单消费者对位）

enum SettingsEffects {

    /// 变更分类后执行副作用（db → Db.reset 内含 invalidateSchema；cdn → 图床热生效；
    /// img → 测试图缓存清理；proxy → SocksTunnel 重建留 P13）。
    @MainActor
    static func apply(old: AppSettings, new: AppSettings, store: SettingsStore) {
        let e = store.changesBetween(old, new)
        if e.db {
            Db.reset()   // 内含 invalidateSchema + 清离线软标记
            store.bumpData()
        }
        if e.cdn {
            CdnRewrite.invalidate()     // rewritten 集/代理窗口/会话池
            CdnRewrite.applyHostOnly()  // 内存 shtHost ← 快照
            store.bumpData()
        }
        if e.img {
            // rebuildImageLoader 对位：测试图内存块清空, 下次加载按新设置重建
            TestImages.clearCache()
        }
        if e.proxy {
            // proxyChanged → 重建 SocksTunnel（数据库 SOCKS 隧道）：本阶段留接线注释,
            // P13 与 Db.configure 一起接入（Socks5Tunnel.start() → 本地端口注入 MySQLPoolSettings）。
        }
    }
}

// MARK: - 离线索引/向量库 hub（懒建；只调用 JDLVCore 公开 API）

/// IdxDb + SyncCoordinator + EmbStore 懒加载单例。
/// 目录布局：Application Support/{idx.db, embs.db}（P13 页面接线复用同一布局）。
@MainActor
final class SettingsIndexHub {

    static let shared = SettingsIndexHub()

    /// 快照盒（单例持有、永不换实例；SettingsView 只做 update 推送，
    /// provider 闭包可直接捕获该实例 —— 避免 SettingsView 重建后闭包拿到旧盒）
    let box = SettingsSnapshotBox()

    private var _sync: SyncCoordinator?
    private var idxFailed = false
    private var _emb: EmbStore?
    private var embFailed = false

    private init() {}

    /// Application Support 目录（含尾分隔符的 path, 与 JDLVCore filePath 拼接规则一致）
    static var supportDir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path.hasSuffix("/") ? base.path : base.path + "/"
    }

    /// WarmSettings 提供器（AppSettings → WarmSettings 映射）
    static func warmSettings(_ s: AppSettings) -> WarmSettings {
        WarmSettings(
            enabled: s.shadowEnabled,
            idxMode: s.shadowMode == 1,
            limitJdb: LimitMath.normalizeStored(s.shadowLimitJdb),
            limitSht: LimitMath.normalizeStored(s.shadowLimitSht),
            actorIndex: s.shadowActorIndex,
            actorLinks: s.shadowActorLinks,
            tagIndex: s.shadowTagIndex)
    }

    /// SyncCoordinator（懒建一次；建失败恒 nil, 调用方按"未启用"展示）
    var sync: SyncCoordinator? {
        if _sync != nil { return _sync }
        if idxFailed { return nil }
        do {
            let idx = try IdxDb(directory: Self.supportDir)
            let snapshot = box
            let coordinator = SyncCoordinator(
                idx: idx,
                source: WarmDbSourceFactory(),
                settings: { SettingsIndexHub.warmSettings(snapshot.settings) })
            _sync = coordinator
            return coordinator
        } catch {
            idxFailed = true
            return nil
        }
    }

    /// 实际占用重算（idx = IdxDb.usageBytes(fast:false) 含 WAL；详情缓存 ShadowDb 未接线 → 0）
    func recalcUsage() -> (idxMb: Double, detailMb: Double) {
        guard let sync else { return (0, 0) }
        let idx = Double(sync.idx.usageBytes(fast: false)) / 1_048_576.0
        return (idx, 0.0)
    }

    // MARK: EmbStore（语义向量缓存）

    /// 懒开 EmbStore（失败恒 nil）
    private func emb() -> EmbStore? {
        if _emb != nil { return _emb }
        if embFailed { return nil }
        do {
            let store = try EmbStore(directory: Self.supportDir)
            _emb = store
            return store
        } catch {
            embFailed = true
            return nil
        }
    }

    /// (条数, 字节)；未就绪 → nil（显示 "…"）
    func embStats() -> (count: Int, bytes: Int64)? {
        guard let e = emb(), let c = try? e.count(), let b = try? e.usageBytes() else { return nil }
        return (Int(c), b)
    }

    /// 容量热更新（S15-14：立即更新 maxBytes 并 trim 至 90%；0 = 不限）
    func applyEmbBudget(mb: Int) {
        guard let e = emb() else { return }
        e.maxBytes = mb <= 0 ? 0 : Int64(mb) * 1_048_576
        try? e.prune()
    }

    /// 清空向量缓存
    func clearEmbs() {
        guard let e = emb() else { return }
        try? e.clear()
    }
}
