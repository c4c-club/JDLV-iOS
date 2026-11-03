import Foundation

// P2 依赖 spike：ONNX Runtime 绑定编译引用（仅 App target，不进 JDLVCore）。
// spike 只实例化 Env / 验证可链接，不加载模型；P11 完成真实推理链路。

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings

enum OrtSpike {
    /// 返回 true 表示 ORT ObjC 绑定可链接（不加载模型）
    static func envAvailable() -> Bool {
        (try? ORTEnv(loggingLevel: .warning)) != nil
    }
}
#else
enum OrtSpike {
    static func envAvailable() -> Bool { false }
}
#endif
