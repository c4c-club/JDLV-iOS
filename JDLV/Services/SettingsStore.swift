//
//  SettingsStore.swift
//  JDLV
//
//  P6：设置存储层，对齐 Android Prefs + MainVm.autoSave 的锁内部分（docs/_extract/11_settings.md、
//  14_vm_tests.md A.1）。设置 UI 留 P12；autoSave 副作用（dbChanged/cdnChanged/imgChanged/
//  proxyChanged 的 Db.reset/CdnRewrite/rebuildImageLoader/bumpData）接线留 P8/P12。
//
//  口径：
//  - 载入同步（init 读 UserDefaults 单键 JSON + Keychain 口令）；口令绝不落 UserDefaults。
//  - 三条写通道（对齐 MainVm）：updateSettings（轻量、立即落盘、无副作用回调）、
//    updateSettingsNow（挂起等落盘，首启配置用）、autoSave（三态：NO_CHANGE=值全等 /
//    FAILED=存储异常 / SAVED=成功；NO_CHANGE 不是失败，UI 不得显示红字）。
//  - 变换链 editChain（S14-P1 B01/R3）：每次 edit 把新变换叠到链尾，800ms 防抖一次性应用
//    全链（防跨字段快速输入丢字段）；editNow 立即落盘。
//  - dataEpoch / netEpoch 手动触发器：bump() API 先留，P8/P12 接线。
//  - 解锁态 unlocked 只在内存（@Published），绝不持久化（A-15 安全不变量）。
//

import Foundation
import SwiftUI
import UIKit
import JDLVCore

/// 设置变换（等价 Android `{ it.copy(...) }`）
public typealias SettingsTransform = (inout AppSettings) -> Void

/// R4 P4：Keychain 物理写入走串行后台 actor（SecItem 调用离主线程；任务 05 §7.5.3）。
/// 原子化预写/回滚的顺序与 persisted* 缓存逻辑仍在 @MainActor SettingsStore（actor 只做单次 set）。
private actor KeychainWriter {
    func set(_ value: String, forKey key: String) -> Result<Void, KeychainStore.KeyStatus> {
        KeychainStore.setResult(value, forKey: key)
    }
}

@MainActor
final class SettingsStore: ObservableObject {

    // MARK: - 状态

    /// 内存快照（等价 Prefs.current）
    @Published private(set) var settings: AppSettings
    /// prefs 是否完成首次 load（Android loaded；iOS 同步载入，恒 true after init）
    @Published private(set) var loaded = false
    /// 应用锁解锁态 —— 只在内存，绝不写磁盘/saved-state（A-15）
    @Published var unlocked = false
    /// 数据源/代理/图床/库名/超时变更 +1 → 各列表页强制刷新（走冷却、静默）（P8 接线）
    @Published private(set) var dataEpoch = 0
    /// 离线→在线恢复 +1 → 只更新横幅，不自动重拉（P1.1/P8 接线）
    @Published private(set) var netEpoch = 0
    /// 最近一次 autoSave 结果（P12 设置页三态状态行：已保存 HH:mm:ss / 无变化 / 保存失败 (重试或检查存储)）
    @Published private(set) var lastSaveResult: SaveResult?

    // MARK: - 全局保存状态（R3 问题 4：单实例 SaveState；替换每卡 SaveStateBus）

    /// 所有写通道统一：入口 .saving → 出口 .saved/.noChange/.failed；5s watchdog 超时。
    @Published private(set) var saveState: SaveState = .idle
    private var saveWatchdog: Task<Void, Never>?

    /// 写通道入口（内部通道自动调用；外部通道 applyLockChange/saveAndSniff 显式调）
    func noteSaving() {
        saveState = .saving(Date())
        saveWatchdog?.cancel()
        saveWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.saveState.isSaving else { return }
            self.saveState = .failed("保存超时", Date())
        }
    }

    /// 写通道出口
    func noteFinished(_ r: SaveResult) {
        saveWatchdog?.cancel()
        saveWatchdog = nil
        switch r {
        case .saved: saveState = .saved(Date())
        case .noChange: saveState = .noChange(Date())
        case .failed: saveState = .failed("保存失败", Date())
        }
    }

    // MARK: A7/R7 Keychain 可观测

    /// 口令读取失败（未解锁/访问被拒等）—— 不得静默当空口令连库
    @Published private(set) var secretReadFailed = false
    /// 口令读取失败的展示文案（UI 卡直接呈现）
    @Published private(set) var secretReadMessage = ""
    /// 最近一次写失败的状态文案（persist FAILED 时由 UI 呈现）
    @Published private(set) var secretWriteMessage = ""
    /// A-7 自愈发生（锁定残留被自动解除）—— UI 提示用
    @Published private(set) var healedResidualLock = false

    /// 首次解锁后系统通知：重试此前失败的口令读取
    private var protectedDataObserver: NSObjectProtocol?

    /// 首启引导判定（07 §A2）
    var setupRequired: Bool { settings.setupRequired }

    // MARK: - A3/R3 副作用单入口

    /// 落盘【成功后】的运行时副作用（reconfigure/Db.reset/隧道收敛/CdnRewrite/
    /// PageCache 清理/bumpData）。由组合根 AppBootstrap 注入 SettingsEffects.apply；
    /// 单测可注入自己的执行器；nil = 不执行（纯逻辑测试）。所有写通道
    /// （updateSettings / updateSettingsNow→autoSave→edit/editNow/flush /
    /// LockView.applyLockChange / 离线上限 / 媒体嗅探落盘）都经这两个收敛点触发。
    var onPersistedEffects: (@MainActor (AppSettings, AppSettings) -> Void)?

    // MARK: - 存储

    let defaults: UserDefaults
    /// R4 P13：搜索历史/测试隔离需要读取 suite（只读暴露；写入仍走 Store 内部）

    private enum SecretKey {
        static let localPass = "settings:local_pass"
        static let remotePass = "settings:remote_pass"
        static let lockSecret = "lock_secret"   // 存 PBKDF2 哈希串
    }

    /// 上次持久化过的口令缓存：值未变时不重复写 Keychain
    private var persistedLocalPass = ""
    private var persistedRemotePass = ""
    private var persistedLockSecret = ""

    /// R4 P4：Keychain 物理写入执行器（串行后台 actor；见文件头说明）
    private let keychainWriter = KeychainWriter()

    enum PersistError: Error {
        case keychainWrite(String)
        case jsonEncode
    }

    // MARK: - A9/R8 UI 测试隔离与种子

    /// launch argument → 独立 UserDefaults suite（未指定 = standard）
    static func defaultsForLaunch(_ args: [String]) -> UserDefaults {
        guard let i = args.firstIndex(of: "-JDLV_DEFAULTS_SUITE"),
              i + 1 < args.count else { return .standard }
        return UserDefaults(suiteName: "jdlv_suite_\(args[i + 1])") ?? .standard
    }

    /// launch argument `-JDLV_SEED_SETTINGS <base64(JSON 存储字典)>` → 预写存储
    /// （仅 DEBUG；ProductionSmokeUITests 用 —— 先种配置再载入，等价已保存的合法配置。
    /// 口令键不进 UserDefaults（与生产一致）：remote_pass/local_pass/lock_secret 写 Keychain。）
    static func applySeedIfPresent(_ args: [String], defaults: UserDefaults) {
        #if DEBUG
        guard let i = args.firstIndex(of: "-JDLV_SEED_SETTINGS"),
              i + 1 < args.count,
              let data = Data(base64Encoded: args[i + 1]),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let s = AppSettings.fromStorage(dict)
        guard let enc = AppSettings.encodeStorageJSON(s.storageWithoutSecrets) else { return }
        defaults.set(enc, forKey: AppSettings.storageDefaultsKey)
        // 口令走 Keychain（与生产同路径；service 已被 -JDLV_KEYCHAIN_SERVICE 隔离）
        if let v = dict["remote_pass"] as? String {
            _ = KeychainStore.setResult(v, forKey: "settings:remote_pass")
        }
        if let v = dict["local_pass"] as? String {
            _ = KeychainStore.setResult(v, forKey: "settings:local_pass")
        }
        if let v = dict["lock_secret"] as? String {
            _ = KeychainStore.setResult(v, forKey: "lock_secret")
        }
        #endif
    }

    // MARK: - init（R4 P6：UserDefaults 同步 + Keychain 三键后台读）

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        KeychainStore.applyLaunchArgFaults(ProcessInfo.processInfo.arguments)
        var s: AppSettings
        if let data = defaults.data(forKey: AppSettings.storageDefaultsKey) {
            s = AppSettings.fromStorageJSON(data)
        } else {
            s = AppSettings()
        }
        self.settings = s
        // R4 P6：Keychain 三键读取移到后台（任务 06 §17.5.5；loaded=false 期间 AppGate 转圈，
        // AppRoot.swift 已有该分支）。读取完成后回主 actor 写内存态 + 刷新启动快照
        // （AppBootstrap.box / 隧道 reconcile —— 否则远端连接会拿到空口令）。
        // 启动 Gate 期间主线程 0 次 Keychain 读取（硬规则 14：≤3 次轻量读取 → 本实现 0 次）。
        self.loaded = false
        // R4 P6 兜底：后台 Keychain 读若异常挂起（模拟器 Keychain 服务偶发慢），
        // 6s 后强制放行主界面（口令空 → 连接失败显式呈现，绝不静默当成功；
        // protectedDataAvailable 观察者/下次保存仍会补齐真实口令）
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !self.loaded else { return }
            self.loaded = true
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var readFailed = false
            var readMsg = ""
            let lp = Self.loadSecretStatic(SecretKey.localPass, &readFailed, &readMsg)
            let rp = Self.loadSecretStatic(SecretKey.remotePass, &readFailed, &readMsg)
            let ls = Self.loadSecretStatic(SecretKey.lockSecret, &readFailed, &readMsg)
            await MainActor.run { [weak self] in
                guard let self else { return }
                var updated = self.settings
                updated.localPass = lp
                updated.remotePass = rp
                updated.lockSecret = ls
                self.persistedLocalPass = lp
                self.persistedRemotePass = rp
                self.persistedLockSecret = ls
                self.settings = updated
                self.secretReadFailed = readFailed
                self.secretReadMessage = readMsg
                self.loaded = true
                self.healResidualLockIfNeeded()
                self.observeProtectedDataAvailable()
                // 启动快照补齐（等价原同步路径 init 时的 box.update；reconcile 内部按键比较，幂等）
                AppBootstrap.box.update(updated)
                ProxyTunnelManager.shared.reconcile(updated)
            }
        }
    }

    /// 单键读取（A7/R7：失败 → 空串 + 失败标记，区分 itemNotFound；init 期静态版）
    /// nonisolated：init 的 detached 闭包在任意线程直调（KeychainStore 静态 API 线程安全）
    nonisolated private static func loadSecretStatic(_ key: String, _ failed: inout Bool, _ msg: inout String) -> String {
        switch KeychainStore.getResult(key) {
        case .success(let v):
            return v ?? ""
        case .failure(let st):
            failed = true
            msg = st.message
            return ""
        }
    }

    /// protectedDataDidBecomeAvailable：重试此前失败的读取（锁屏首启场景）
    private func observeProtectedDataAvailable() {
        guard secretReadFailed, protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retrySecretLoads() }
        }
    }

    /// 重试读取：全部成功 → 清失败态 + 刷新内存 + 移除观察者
    func retrySecretLoads() {
        guard secretReadFailed else { return }
        var anyFail = false
        var msgs: String = ""
        let lp = readOrTrack(SecretKey.localPass, &anyFail, &msgs)
        let rp = readOrTrack(SecretKey.remotePass, &anyFail, &msgs)
        let ls = readOrTrack(SecretKey.lockSecret, &anyFail, &msgs)
        guard !anyFail else {
            secretReadMessage = msgs
            return
        }
        secretReadFailed = false
        secretReadMessage = ""
        var s = settings
        if lp != persistedLocalPass { s.localPass = lp; persistedLocalPass = lp }
        if rp != persistedRemotePass { s.remotePass = rp; persistedRemotePass = rp }
        if ls != persistedLockSecret { s.lockSecret = ls; persistedLockSecret = ls }
        settings = s
        if let o = protectedDataObserver {
            NotificationCenter.default.removeObserver(o)
            protectedDataObserver = nil
        }
    }

    private func readOrTrack(_ key: String, _ anyFail: inout Bool, _ msgs: inout String) -> String {
        switch KeychainStore.getResult(key) {
        case .success(let v):
            return v ?? ""
        case .failure(let st):
            anyFail = true
            msgs = st.message
            return ""
        }
    }

    /// A-7 自愈：`lockEnabled && lockType != "biometric" && lockSecret 空`（切换认证方式残留）
    /// → 自动写回 lockEnabled=false, lockType="none", lockSecret=""，防永久锁死。
    /// R4 P4：persist 已 async（KeychainWriter 后台写）→ 自愈改为 fire-and-forget Task，
    /// 不阻断启动（内存态先按 fixed 生效由下一次保存兜底 —— 原语义不变）。
    private func healResidualLockIfNeeded() {
        let s = settings
        guard s.lockEnabled, s.lockType != "biometric", s.lockSecret.isEmpty else { return }
        var fixed = s
        fixed.lockEnabled = false
        fixed.lockType = "none"
        fixed.lockSecret = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.persist(fixed)
                self.settings = fixed
                self.healedResidualLock = true
            } catch {
                // 自愈落盘失败不阻断启动（内存态已修正，下次保存会再写）
            }
        }
    }

    // MARK: - 落盘

    /// 全量落盘：口令（remote_pass/local_pass/lock_secret）写 Keychain；
    /// 其余 69 键 JSON 编码后写 UserDefaults 单键 `jdlv_settings_v1`。
    /// A7/R7：口令三键原子化 —— 预写校验，任一失败回滚已写键到 persisted* 旧值，
    /// 抛 PersistError（绝不半写）；写失败文案入 secretWriteMessage。
    /// R4 P4：Keychain 物理写入走串行后台 KeychainWriter actor（SecItem 离主线程）；
    /// 原子顺序与缓存逻辑仍在主 actor，主线程不再做 Keychain I/O。
    private func persist(_ s: AppSettings) async throws {
        var wrote: [(key: String, oldValue: String)] = []
        do {
            if s.localPass != persistedLocalPass {
                try await writeSecretViaWriter(s.localPass, forKey: SecretKey.localPass)
                wrote.append((SecretKey.localPass, persistedLocalPass))
                persistedLocalPass = s.localPass
            }
            if s.remotePass != persistedRemotePass {
                try await writeSecretViaWriter(s.remotePass, forKey: SecretKey.remotePass)
                wrote.append((SecretKey.remotePass, persistedRemotePass))
                persistedRemotePass = s.remotePass
            }
            if s.lockSecret != persistedLockSecret {
                try await writeSecretViaWriter(s.lockSecret, forKey: SecretKey.lockSecret)
                wrote.append((SecretKey.lockSecret, persistedLockSecret))
                persistedLockSecret = s.lockSecret
            }
        } catch {
            // 回滚已写键（尽力而为：恢复旧值与缓存，保持内存/磁盘一致）
            for w in wrote {
                _ = await keychainWriter.set(w.oldValue, forKey: w.key)
                switch w.key {
                case SecretKey.localPass: persistedLocalPass = w.oldValue
                case SecretKey.remotePass: persistedRemotePass = w.oldValue
                case SecretKey.lockSecret: persistedLockSecret = w.oldValue
                default: break
                }
            }
            if case PersistError.keychainWrite(let msg) = error {
                secretWriteMessage = msg
            }
            throw error
        }
        guard let data = AppSettings.encodeStorageJSON(s.storageWithoutSecrets) else {
            throw PersistError.jsonEncode
        }
        defaults.set(data, forKey: AppSettings.storageDefaultsKey)
    }

    /// 单口令键物理写入（KeychainWriter actor；失败抛 PersistError.keychainWrite 可读文案）
    private func writeSecretViaWriter(_ value: String, forKey key: String) async throws {
        switch await keychainWriter.set(value, forKey: key) {
        case .success:
            break
        case .failure(let st):
            throw PersistError.keychainWrite(st.message)
        }
    }

    // MARK: - 写通道一：updateSettings（轻量，立即落盘，无三态回调）

    /// 主题/视图/每页数量等纯展示设置用；落盘失败不阻断内存生效（下次保存重写）。
    /// A3/R3：副作用只在【落盘成功】后经 onPersistedEffects 单入口执行。
    /// R3 问题 4：值未变 → .noChange；落盘异常 → .failed；成功 → .saved。
    /// R4 P4：persist 已 async（KeychainWriter 后台写）→ 本通道保持同步签名（VM 有大量
    /// 同步调用方），落盘部分改 fire-and-forget Task：内存立即生效（原语义），后台完成后
    /// 触发副作用/三态。
    func updateSettings(_ transform: SettingsTransform) {
        var next = settings
        transform(&next)
        guard next != settings else {
            noteFinished(.noChange)
            return
        }
        noteSaving()
        let old = settings
        settings = next   // 内存立即生效（原语义：失败不回滚，下次保存重写）
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.persist(next)
                self.onPersistedEffects?(old, next)
                self.noteFinished(.saved)
            } catch {
                // 落盘失败：内存已生效（展示态），但不触发运行时副作用（A3：失败不触发）
                self.noteFinished(.failed)
            }
        }
    }

    // MARK: - 写通道二：updateSettingsNow（挂起等落盘；首启配置/上限对话框用）

    /// 值未变 → NO_CHANGE（不写盘）；落盘异常 → FAILED；否则 SAVED。
    /// A3/R3：SAVED 才执行副作用（onPersistedEffects），FAILED 一律不触发。
    /// R3 问题 4：saveState 同步出口（不再依赖每卡 bus）。
    @discardableResult
    func updateSettingsNow(_ transform: @escaping SettingsTransform) async -> SaveResult {
        var next = settings
        transform(&next)
        guard next != settings else {
            noteFinished(.noChange)
            return .noChange
        }
        noteSaving()
        do {
            try await persist(next)
            let old = settings
            settings = next
            onPersistedEffects?(old, next)
            noteFinished(.saved)
            return .saved
        } catch {
            noteFinished(.failed)
            return .failed
        }
    }

    // MARK: - 写通道三：autoSave（三态；副作用接线留 P8/P12）

    /// 锁内语义（对齐 MainVm.autoSave）：transform 后 `next == old` → NO_CHANGE；
    /// 落盘异常 → FAILED；否则 SAVED。副作用判定见 changesBetween（P8 消费）。
    @discardableResult
    func autoSave(_ transform: @escaping SettingsTransform) async -> SaveResult {
        let result = await updateSettingsNow(transform)
        lastSaveResult = result
        return result
    }

    // MARK: - 变换链（S14-P1：800ms 防抖合并连续编辑）

    private var editChain: [SettingsTransform] = []
    private var pendingEditTask: Task<Void, Never>?

    /// 文本输入用：draft 由页面自持；新变换叠到链尾，800ms 防抖后一次性 autoSave 全链
    /// （跨字段快速输入 主机→端口→用户→密码 不丢字段）。
    func edit(_ transform: @escaping SettingsTransform) {
        editChain.append(transform)
        pendingEditTask?.cancel()
        pendingEditTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            let chain = self.editChain
            self.editChain = []
            self.pendingEditTask = nil
            let merged: SettingsTransform = { s in
                for step in chain { step(&s) }
            }
            _ = await self.autoSave(merged)
        }
    }

    /// 开关/选择用：取出并清空链、取消 pending，合并链立即落盘。
    @discardableResult
    func editNow(_ transform: @escaping SettingsTransform) async -> SaveResult {
        let chain = editChain
        editChain = []
        pendingEditTask?.cancel()
        pendingEditTask = nil
        return await autoSave { s in
            for step in chain { step(&s) }
            transform(&s)
        }
    }

    /// 页面销毁时调用：取消未触发的防抖任务并把未落盘的全链编辑立即落盘
    /// （对齐 SettingsScreen onDispose；此时无三态回调）。
    func flushPendingEdits() async {
        guard !editChain.isEmpty else {
            pendingEditTask?.cancel()
            pendingEditTask = nil
            return
        }
        _ = await editNow { _ in }   // 取出全链立即落盘（无新增变换）
    }

    // MARK: - epoch 触发器（P8/P12 接线占位）

    /// 数据源/代理/图床/库名/超时变更后调用（列表页订阅走 60s 冷却、静默刷新）
    func bumpData() { dataEpoch += 1 }

    /// 离线→在线恢复后调用（只更新横幅，不自动重拉）
    func bumpNet() { netEpoch += 1 }

    // MARK: - 副作用判定（P8 接线占位；字段数对齐 MainVm autoSave）

    struct SaveEffect {
        var db = false     // dbChanged   15 字段 → Db.reset + QCache.clearDisk + CdnRewrite.invalidate + rebuildImageLoader + bumpData
        var cdn = false    // cdnChanged   8 字段 → invalidate + rebuild + bumpData
        var img = false    // imgChanged   2 字段 → rebuild + sweepImageCache
        var proxy = false  // proxyChanged 4 字段
        var none: Bool { !db && !cdn && !img && !proxy }
    }

    /// 变更分类（P8 消费；字段清单按 14_vm_tests A.1 的 15/8/2/4 计数复刻，P8 接线时逐字段核对）。
    /// 注意 jdbSortAsc 不纳入 dbChanged（S11-P2：排序变化不触发全页重建连接）。
    func changesBetween(_ old: AppSettings, _ new: AppSettings) -> SaveEffect {
        var e = SaveEffect()
        // dbChanged 16：db_src + 本地 6 + 远程 6 + db_ssl + query_timeout + connect_timeout（A10/R9 纳入）
        e.db = old.dbSrc != new.dbSrc
            || old.localHost != new.localHost || old.localPort != new.localPort
            || old.localUser != new.localUser || old.localPass != new.localPass
            || old.localJdb != new.localJdb || old.localSht != new.localSht
            || old.remoteHost != new.remoteHost || old.remotePort != new.remotePort
            || old.remoteUser != new.remoteUser || old.remotePass != new.remotePass
            || old.remoteJdb != new.remoteJdb || old.remoteSht != new.remoteSht
            || old.dbSsl != new.dbSsl || old.queryTimeout != new.queryTimeout
            || old.connectTimeout != new.connectTimeout
        // cdnChanged 8：proxy_host/port + proxy_cdn(+jdb/sht) + jdb_img_host + sht_mirror(+host)
        e.cdn = old.proxyHost != new.proxyHost || old.proxyPort != new.proxyPort
            || old.proxyCdn != new.proxyCdn
            || old.proxyCdnJdb != new.proxyCdnJdb || old.proxyCdnSht != new.proxyCdnSht
            || old.jdbImgHost != new.jdbImgHost
            || old.shtMirror != new.shtMirror || old.shtMirrorHost != new.shtMirrorHost
        // imgChanged 2：image_cache_mb / image_cache_days
        e.img = old.imageCacheMb != new.imageCacheMb || old.imageCacheDays != new.imageCacheDays
        // proxyChanged 4：proxy_host/port/db/cdn
        e.proxy = old.proxyHost != new.proxyHost || old.proxyPort != new.proxyPort
            || old.proxyDb != new.proxyDb || old.proxyCdn != new.proxyCdn
        return e
    }

    // MARK: - 解锁态（内存）

    /// 应用锁解锁（A-15：绝不持久化；进程重启即失效）
    func markUnlocked() { unlocked = true }

    /// 上锁（调试/测试用；正常流程只在进程内保持解锁）
    func markLocked() { unlocked = false }
}
