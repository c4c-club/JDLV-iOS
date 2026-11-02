import Foundation

// P2 依赖 spike：ONNX Runtime 绑定编译引用（仅 App target，不进 JDLVCore）。
// 模块名以构建日志为准（OnnxRuntimeBindings 为 SPM target 名）；spike 只实例化
// Env/验证可链接，不加载模型。P11 完成真实推理链路。

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings

enum OrtSpike {
    /// 返回 true 表示 ORT C 绑定可链接（不加载模型）
    static func envAvailable() -> Bool {
        // OrtGetApiBase 是纯 C 入口；此处只验证符号可解析
        let base = OrtGetApiBase()
        return base != nil
    }
}
#else
enum OrtSpike {
    static func envAvailable() -> Bool { false }
}
#endif
