import LocalAuthentication

//
//  BiometryLabel.swift —— 启动锁生物识别文案（R3 问题 3：面容/触控动态识别）。
//
//  iOS 设备 Face ID 是主流 → 默认文案「面容 ID」；LAContext.biometryType 动态判定；
//  .none（模拟器/无生物识别硬件）→「生物识别」。Info.plist 已有 NSFaceIDUsageDescription。
//

enum BiometryLabel {
    /// 按设备能力返回文案：faceID → 面容 ID / touchID → 触控 ID / 其他 → 生物识别
    static func text(for context: LAContext) -> String {
        switch context.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        default: return "生物识别"
        }
    }

    /// 当前设备文案（新 LAContext；canEvaluatePolicy 不在此判定——只取硬件类型）
    static var current: String { text(for: LAContext()) }
}
