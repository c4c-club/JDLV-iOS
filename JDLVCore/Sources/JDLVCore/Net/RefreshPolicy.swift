import Foundation

/// 自动刷新策略：60 秒冷却。
/// lastAt==0（从未自动刷新过）或距上次 ≥ 冷却期 → 允许。
public enum RefreshPolicy {
    public static let AUTO_COOLDOWN_MS: Int64 = 60_000

    public static func shouldAuto(_ lastAt: Int64, now: Int64) -> Bool {
        lastAt == 0 || now - lastAt >= AUTO_COOLDOWN_MS
    }
}
