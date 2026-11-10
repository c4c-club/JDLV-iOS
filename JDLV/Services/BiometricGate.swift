import LocalAuthentication

/// R4 口令 UI 硬化：查看数据库口令明文前必须通过
/// 生物识别 / 设备密码（.deviceOwnerAuthentication）。
/// 无可用认证方式（canEvaluatePolicy 失败，如未设设备密码的模拟器）→ 拒绝展示。
enum BiometricGate {
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
