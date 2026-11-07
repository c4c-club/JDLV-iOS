import Foundation
import Security

// 口令存储（对齐 Android SecretVault 语义）：只进 Keychain，绝不落 UserDefaults。
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly（不随备份迁移）。
//
// A7/R7：读写一律 Result 化并区分 errSecItemNotFound 与
// errSecInteractionNotAllowed / errSecAuthFailed（锁屏首启/生物保护）等真实 OSStatus，
// 上层（SettingsStore）据此暴露 secretReadFailed/secretWriteFailed 并可重试，
// 不再把错误静默映射成空口令。
//
// 故障注入（A9/R8 UI 用例 + 单测）：DEBUG 下 launch argument
// -JDLV_KEYCHAIN_FAIL_READ / -JDLV_KEYCHAIN_FAIL_WRITE，或单测直接置 `fault`。

enum KeychainStore {
    /// Keychain service（A9/R8：UI 测试可用 -JDLV_KEYCHAIN_SERVICE 覆盖实现完全隔离）
    static var service = "com.jdlv.ios"

    /// launch argument → service 覆盖（App 启动时调用一次）
    static func applyServiceOverride(_ args: [String]) {
        if let i = args.firstIndex(of: "-JDLV_KEYCHAIN_SERVICE"), i + 1 < args.count {
            service = args[i + 1]
        }
    }

    // MARK: 故障注入（仅测试）

    struct Fault {
        var read = false
        var write = false
        /// 仅这些 key 写失败（构造「部分写」场景用）
        var failKeys: Set<String> = []
    }

    /// 单测直接置位；进程启动时由 launch argument 驱动（见 init_from_args）
    static var fault = Fault()

    /// launch argument → 故障注入（App 启动时调用一次）
    static func applyLaunchArgFaults(_ args: [String]) {
        fault.read = fault.read || args.contains("-JDLV_KEYCHAIN_FAIL_READ")
        fault.write = fault.write || args.contains("-JDLV_KEYCHAIN_FAIL_WRITE")
    }

    // MARK: 类型化状态

    struct KeyStatus: Error {
        let osStatus: OSStatus

        var isItemNotFound: Bool { osStatus == errSecItemNotFound }
        /// 首次解锁前访问 / 用户拒绝 / 认证失败 —— 「口令不可用，请重新输入」语义
        var isAccessDenied: Bool {
            osStatus == errSecInteractionNotAllowed || osStatus == errSecAuthFailed
        }
        var message: String {
            switch osStatus {
            case errSecItemNotFound: return "钥匙串条目不存在"
            case errSecInteractionNotAllowed: return "口令暂不可用（设备未解锁）"
            case errSecAuthFailed: return "口令访问被拒绝"
            default: return "钥匙串错误 (\(osStatus))"
            }
        }
    }

    // MARK: 写

    @discardableResult
    static func setResult(_ value: String, forKey key: String) -> Result<Void, KeyStatus> {
        if fault.write || fault.failKeys.contains(key) {
            return .failure(KeyStatus(osStatus: errSecInteractionNotAllowed))
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            return update == errSecSuccess
                ? .success(())
                : .failure(KeyStatus(osStatus: update))
        }
        if status == errSecItemNotFound {
            var add = query
            for (k, v) in attrs { add[k] = v }
            let added = SecItemAdd(add as CFDictionary, nil)
            return added == errSecSuccess
                ? .success(())
                : .failure(KeyStatus(osStatus: added))
        }
        return .failure(KeyStatus(osStatus: status))
    }

    // MARK: 读

    static func getResult(_ key: String) -> Result<String?, KeyStatus> {
        if fault.read {
            return .failure(KeyStatus(osStatus: errSecInteractionNotAllowed))
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data else {
                return .failure(KeyStatus(osStatus: errSecSuccess))
            }
            return .success(String(data: data, encoding: .utf8))
        }
        if status == errSecItemNotFound {
            return .success(nil)
        }
        return .failure(KeyStatus(osStatus: status))
    }

    // MARK: 兼容包装（旧调用点语义保持）

    static func set(_ value: String, forKey key: String) -> Bool {
        if case .success = setResult(value, forKey: key) { return true }
        return false
    }

    static func get(_ key: String) -> String? {
        (try? getResult(key).get()) ?? nil
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
