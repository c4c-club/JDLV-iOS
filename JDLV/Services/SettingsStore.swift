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
import JDLVCore

/// 设置变换（等价 Android `{ it.copy(...) }`）
public typealias SettingsTransform = (inout AppSettings) -> Void

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

    /// 首启引导判定（07 §A2）
    var setupRequired: Bool { settings.setupRequired }

    // MARK: - 存储

    private let defaults: UserDefaults

    private enum SecretKey {
        static let localPass = "settings:local_pass"
        static let remotePass = "settings:remote_pass"
        static let lockSecret = "lock_secret"   // 存 PBKDF2 哈希串
    }

    /// 上次持久化过的口令缓存：值未变时不重复写 Keychain
    private var persistedLocalPass = ""
    private var persistedRemotePass = ""
    private var persistedLockSecret = ""

    enum PersistError: Error {
        case keychainWrite(String)
        case jsonEncode
    }

    // MARK: - init（同步 load）

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var s: AppSettings
        if let data = defaults.data(forKey: AppSettings.storageDefaultsKey) {
            s = AppSettings.fromStorageJSON(data)
        } else {
            s = AppSettings()
        }
        // 口令走 Keychain（missing → 默认空串）
        s.localPass = KeychainStore.get(SecretKey.localPass) ?? ""
        s.remotePass = KeychainStore.get(SecretKey.remotePass) ?? ""
        s.lockSecret = KeychainStore.get(SecretKey.lockSecret) ?? ""
        persistedLocalPass = s.localPass
        persistedRemotePass = s.remotePass
        persistedLockSecret = s.lockSecret

        self.settings = s
        self.loaded = true
        self.healResidualLockIfNeeded()
    }

    /// A-7 自愈：`lockEnabled && lockType != "biometric" && lockSecret 空`（切换认证方式残留）
    /// → 自动写回 lockEnabled=false, lockType="none", lockSecret=""，防永久锁死。
    private func healResidualLockIfNeeded() {
        let s = settings
        guard s.lockEnabled, s.lockType != "biometric", s.lockSecret.isEmpty else { return }
        var fixed = s
        fixed.lockEnabled = false
        fixed.lockType = "none"
        fixed.lockSecret = ""
        do {
            try persist(fixed)
            settings = fixed
        } catch {
            // 自愈落盘失败不阻断启动（内存态已修正，下次保存会再写）
        }
    }

    // MARK: - 落盘

    /// 全量落盘：口令（remote_pass/local_pass/lock_secret）写 Keychain；
    /// 其余 69 键 JSON 编码后写 UserDefaults 单键 `jdlv_settings_v1`。
    private func persist(_ s: AppSettings) throws {
        if s.localPass != persistedLocalPass {
            guard KeychainStore.set(s.localPass, forKey: SecretKey.localPass) else {
                throw PersistError.keychainWrite(SecretKey.localPass)
            }
            persistedLocalPass = s.localPass
        }
        if s.remotePass != persistedRemotePass {
            guard KeychainStore.set(s.remotePass, forKey: SecretKey.remotePass) else {
                throw PersistError.keychainWrite(SecretKey.remotePass)
            }
            persistedRemotePass = s.remotePass
        }
        if s.lockSecret != persistedLockSecret {
            guard KeychainStore.set(s.lockSecret, forKey: SecretKey.lockSecret) else {
                throw PersistError.keychainWrite(SecretKey.lockSecret)
            }
            persistedLockSecret = s.lockSecret
        }
        guard let data = AppSettings.encodeStorageJSON(s.storageWithoutSecrets) else {
            throw PersistError.jsonEncode
        }
        defaults.set(data, forKey: AppSettings.storageDefaultsKey)
    }

    // MARK: - 写通道一：updateSettings（轻量，立即落盘，无副作用回调）

    /// 主题/视图/每页数量等纯展示设置用；落盘失败不阻断内存生效（下次保存重写）。
    func updateSettings(_ transform: SettingsTransform) {
        var next = settings
        transform(&next)
        guard next != settings else { return }
        try? persist(next)
        settings = next
    }

    // MARK: - 写通道二：updateSettingsNow（挂起等落盘；首启配置/上限对话框用）

    /// 值未变 → NO_CHANGE（不写盘）；落盘异常 → FAILED；否则 SAVED。
    @discardableResult
    func updateSettingsNow(_ transform: @escaping SettingsTransform) async -> SaveResult {
        var next = settings
        transform(&next)
        guard next != settings else { return .noChange }
        do {
            try persist(next)
            settings = next
            return .saved
        } catch {
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
        // dbChanged 15：db_src + 本地 6 + 远程 6 + db_ssl + query_timeout
        e.db = old.dbSrc != new.dbSrc
            || old.localHost != new.localHost || old.localPort != new.localPort
            || old.localUser != new.localUser || old.localPass != new.localPass
            || old.localJdb != new.localJdb || old.localSht != new.localSht
            || old.remoteHost != new.remoteHost || old.remotePort != new.remotePort
            || old.remoteUser != new.remoteUser || old.remotePass != new.remotePass
            || old.remoteJdb != new.remoteJdb || old.remoteSht != new.remoteSht
            || old.dbSsl != new.dbSsl || old.queryTimeout != new.queryTimeout
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
