import Foundation

/// 离线软标记统一门（分库独立 TTL，纯逻辑可单测，now 可注入）。
/// 状态机：在线 = until == 0 或 now >= until；离线 = now < until（严格小于）。
public final class OfflineGate {
    private static let lock = NSLock()
    private static var untilJdb: Int64 = 0
    private static var untilSht: Int64 = 0

    public static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public static func mark(_ which: String, ttlMs: Int64, now: Int64? = nil) {
        let until = (now ?? nowMs()) + ttlMs
        lock.lock(); defer { lock.unlock() }
        if which == "jdb" { untilJdb = until } else { untilSht = until }
    }

    public static func clear(_ which: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if which == nil || which == "jdb" { untilJdb = 0 }
        if which == nil || which == "sht" { untilSht = 0 }
    }

    public static func isOffline(_ which: String, now: Int64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let until = which == "jdb" ? untilJdb : untilSht
        return (now ?? nowMs()) < until
    }

    public static var allOffline: Bool {
        isOffline("jdb") || isOffline("sht")
    }

    /// 测试辅助：全部归零
    public static func reset(now: Int64 = 0) {
        lock.lock(); defer { lock.unlock() }
        untilJdb = now
        untilSht = now
    }
}
