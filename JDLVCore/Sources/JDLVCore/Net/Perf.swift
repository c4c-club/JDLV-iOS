import Foundation

/// 统一性能埋点（对齐 Android `core/net/Perf.kt`，S0）。
///
/// 输出格式: `"<name> | <ms>ms | <extra>"` 或 `"<name> | mark | <extra>"`。
/// 维度约定（name 前缀）:
///   db.*      远程 MySQL 查询 (DbPool/Db.query)
///   qcache.*  页缓存读写 (QCache/PageCache)
///   semantic.* ONNX 推理 / 向量打分
///   vm.*      ViewModel 一次 fetch 起止 (含结果条数)
///   ui.*      页面进入 / 首批数据到位 (一次性 mark)
///   shadow.*  本地影子库 / FTS
///   img.*     图片管线
///   cdn.*     图床嗅探 / 设置热生效
///
/// 日志纪律（原文）: extra 里禁止出现口令 / 完整带参 URL; SQL 一律截断 120 字符
/// （Perf.sql）。Core 保持 Foundation-only：输出目的地经 PerfSink 注入
/// （App 层接 os.Logger）；默认 NoopPerfSink，不产生任何输出。
public protocol PerfSink {
    /// 计时开始钩子（token = begin 返回值，约定为当前墙钟毫秒）。
    /// 对齐 Android：begin 本身不打日志，此钩子仅供注入方按需留痕。
    func begin(_ name: String, token: Int64)
    /// 计时结束: name | ms | extra
    func end(_ name: String, token: Int64, ms: Int64, extra: String)
    /// 一次性事件: name | mark | extra
    func mark(_ name: String, extra: String)
}

/// 默认 no-op sink（Core 内零输出、零分配）
public struct NoopPerfSink: PerfSink {
    public init() {}
    public func begin(_ name: String, token: Int64) {}
    public func end(_ name: String, token: Int64, ms: Int64, extra: String) {}
    public func mark(_ name: String, extra: String) {}
}

public enum Perf {
    public static let TAG = "jdlv-perf"

    /// release 构建默认仍开启（对齐 Android 头注释: 日志量可控, 需要时可整体关掉）
    public static var enabled: Bool = true

    /// 全局 sink 注入点（App 层启动时赋值一次；默认 no-op）
    public static var sink: PerfSink = NoopPerfSink()

    /// SQL 截断到 120 字符（压成单行, 避免多行 SQL 打爆日志）。
    /// 空白折叠为单空格（不 trim、不转小写），超 120 字符截断 + "…"。
    /// 委托 SqlPolicy.perfSql（单一出处; 历史: SqlPolicy 先于本模块落地）。
    public static func sql(_ sql: String) -> String {
        SqlPolicy.perfSql(sql)
    }

    /// 一次性事件
    public static func mark(_ name: String, _ extra: String = "") {
        guard enabled else { return }
        sink.mark(name, extra: extra)
    }

    /// 开始计时, 返回 token（传给 end）
    public static func begin(_ name: String) -> Int64 {
        let t = nowMs()
        guard enabled else { return t }
        sink.begin(name, token: t)
        return t
    }

    /// 结束计时 (token = begin 的返回值)
    public static func end(_ name: String, _ token: Int64, _ extra: String = "") {
        guard enabled else { return }
        sink.end(name, token: token, ms: nowMs() - token, extra: extra)
    }

    /// 当前墙钟毫秒（System.currentTimeMillis 对位）
    public static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
