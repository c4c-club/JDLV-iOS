import Foundation

/// 索引占用纯计算：total = max(0, mainBytes) + max(0, walBytes)（负值钳 0）。
public enum UsageMath {
    public static func total(_ mainBytes: Int64, _ walBytes: Int64) -> Int64 {
        max(0, mainBytes) + max(0, walBytes)
    }
}

/// 写健康度打点：连续失败 ≥5 触发 onFailure（每次 ≥5 后的继续失败仍触发）。
public final class IdxWriteStats {
    public private(set) var okCount: Int64 = 0
    public private(set) var failCount: Int64 = 0
    public private(set) var consecutiveFail: Int = 0
    public private(set) var lastError: String = ""

    /// 连续失败达到阈值时回调（避免 cache → sync 反向依赖）
    public var onFailure: ((String) -> Void)?

    public init() {}

    public func ok() {
        okCount += 1
        consecutiveFail = 0
    }

    public func fail(op: String, error: Error) -> Int {
        failCount += 1
        consecutiveFail += 1
        let msg = String((error.localizedDescription).prefix(120))
        lastError = "\(op) \(String(describing: type(of: error))): \(msg)"
        if consecutiveFail >= 5 { onFailure?(lastError) }
        return consecutiveFail
    }

    public func reset() {
        okCount = 0; failCount = 0; consecutiveFail = 0; lastError = ""
    }
}
