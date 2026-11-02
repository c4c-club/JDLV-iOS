import Foundation

/// 设置保存三态。NO_CHANGE 不是失败（改回原值/点已选 chip 不显示红字）。
/// rawValue 顺序锁定：saved < noChange < failed（等价 Android ordinal 断言）。
public enum SaveResult: Int, CaseIterable {
    case saved = 0
    case noChange = 1
    case failed = 2

    /// 等价 Android valueOf("SAVED")
    public static func named(_ s: String) -> SaveResult? {
        switch s {
        case "SAVED": return .saved
        case "NO_CHANGE": return .noChange
        case "FAILED": return .failed
        default: return nil
        }
    }
}
