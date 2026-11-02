import Foundation

/// 预热巡检门禁输入（字段与 Android WarmGateInput 逐字对应）。
public struct WarmGateInput {
    public var foreground: Bool
    public var idleMs: Int64
    public var enabled: Bool
    public var running: Bool
    public var wifi: Bool
    public var onlineM: Bool
    public var onlineT: Bool
    public var doneM: Bool
    public var doneT: Bool
    public var doneA: Bool
    public var actorsEnabled: Bool
    public var now: Int64
    public var nextRunAt: Int64

    public init(
        foreground: Bool, idleMs: Int64, enabled: Bool, running: Bool, wifi: Bool,
        onlineM: Bool, onlineT: Bool, doneM: Bool, doneT: Bool, doneA: Bool,
        actorsEnabled: Bool, now: Int64, nextRunAt: Int64
    ) {
        self.foreground = foreground
        self.idleMs = idleMs
        self.enabled = enabled
        self.running = running
        self.wifi = wifi
        self.onlineM = onlineM
        self.onlineT = onlineT
        self.doneM = doneM
        self.doneT = doneT
        self.doneA = doneA
        self.actorsEnabled = actorsEnabled
        self.now = now
        self.nextRunAt = nextRunAt
    }
}

/// 预热巡检门禁（短路序）：background → not-idle(≤3000ms) → disabled → running
/// → not-wifi → source-pending → due → backoff。自动起跑仅当 reason ∈ {source-pending, due}。
public enum WarmGate {
    public static func shouldStart(_ i: WarmGateInput) -> Bool {
        let r = reason(i)
        return r == "source-pending" || r == "due"
    }

    public static func reason(_ i: WarmGateInput) -> String {
        if !i.foreground { return "background" }
        if i.idleMs <= 3_000 { return "not-idle" }
        if !i.enabled { return "disabled" }
        if i.running { return "running" }
        if !i.wifi { return "not-wifi" }
        let pendingM = i.onlineM && !i.doneM
        let pendingT = i.onlineT && !i.doneT
        let pendingA = i.onlineM && i.actorsEnabled && !i.doneA
        if pendingM || pendingT || pendingA { return "source-pending" }
        if i.now >= i.nextRunAt { return "due" }
        return "backoff"
    }
}
