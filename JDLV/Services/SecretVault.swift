import Foundation
import JDLVCore

/// R7 P1 安装代际清零：iOS Keychain 条目不随 App 删除而消失，卸载重装 / 换机恢复后
/// 若不清理，设置页会回填历史 DB 口令（安装代际泄露）。判定键 = UserDefaults
/// `jdlv_install_id`（App 删除即消失）：无标记 = 新代际 → 在读取任何口令之前 purge；
/// 有标记 = 同代际（正常重启/升级），绝不清（保证口令跨启动保留）。
/// purge 全部成功才写标记；任一删除失败 → 不写标记，本会话按「无口令」处理
/// （SettingsStore.secretPurgePending），下次启动 ensureGeneration 幂等重试。
enum SecretVault {
    static let installIDKey = "jdlv_install_id"

    /// DB 口令键（与 SettingsStore.SecretKey 同名）。
    /// lock_secret 是应用锁 PBKDF2 哈希、不是 DB 凭据：仅在 lock_enabled=false 时
    /// 随代际清理（升级路径清掉会让已开锁用户静默失去锁）。
    static let dbSecretKeys = ["settings:local_pass", "settings:remote_pass"]
    static let lockSecretKey = "lock_secret"

    /// purge 覆盖的历史 service 名（git log -S 'service = ' 证实 iOS 历史上仅
    /// com.jdlv.ios 一个；将来 service 迁移时在此追加旧名，与当前 service 一起清）。
    static let legacyServices: [String] = []

    /// 删除每个 service × key 的 Keychain 条目；errSecItemNotFound 视为成功；
    /// 全部成功才返回 true（任一失败 = false，上层不写代际标记）。
    @discardableResult
    static func purgeDBSecrets(includingLock: Bool) -> Bool {
        let services = [KeychainStore.service] + legacyServices
        let keys = includingLock ? dbSecretKeys + [lockSecretKey] : dbSecretKeys
        var ok = true
        for svc in services {
            for key in keys {
                let st = KeychainStore.deleteResult(key, service: svc)
                if st != noErr && st != errSecItemNotFound { ok = false }
            }
        }
        return ok
    }

    /// 存储 JSON 里的 lock_enabled（只读 defaults，不读 Keychain）；
    /// 无 JSON / 解不出 = false（全新安装必清锁）。
    private static func storedLockEnabled(defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: AppSettings.storageDefaultsKey) else { return false }
        return AppSettings.fromStorageJSON(data).lockEnabled
    }

    /// 无标记 = 新安装代际：purge 成功才写 UUID（true）；失败不写标记（false）。
    /// 已有标记 = 同代际直接 true（幂等，不清任何条目）。
    @discardableResult
    static func ensureGeneration(defaults: UserDefaults) -> Bool {
        if defaults.string(forKey: installIDKey) != nil { return true }
        let includingLock = !storedLockEnabled(defaults: defaults)
        guard purgeDBSecrets(includingLock: includingLock) else { return false }
        defaults.set(UUID().uuidString, forKey: installIDKey)
        return true
    }
}
