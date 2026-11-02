import Foundation
import MySQLNIO

/// 异常分类与用户文案（对齐 Android ErrText.kt）。
/// 只有 isConn 判定为"连接级"的异常才允许出现"不可达"字样。
public enum ErrText {

    /// 有明确语义的 MySQL 错误码：1044/1045 账号, 1049 库名, 1146 表, 1054 列, 1064 语法
    static let SEMANTIC_CODES: Set<Int> = [1044, 1045, 1049, 1146, 1054, 1064]

    /// 消息兜底标记（连接失败类）
    static let MSG_MARKERS = [
        "Communications link failure", "Unable to connect",
        "Connection refused", "Unknown database", "UnknownHost",
        "Connection reset", "Broken pipe",
    ]

    /// 连接级异常的类名标记（Swift 侧：NIO 网络错误类型名）
    static let CONN_TYPE_MARKERS = [
        "NIOConnectionError", "ChannelError", "NIOSSLError",
        "ConnectionReset", "BrokenPipe", "UnknownHost", "GetaddrinfoError",
    ]

    public static func of(_ e: Error) -> String {
        if let n = e as? NoNetworkError {
            return n.message.isBlank ? "无网络连接 — 正在显示本地缓存" : n.message
        }
        if let t = e as? QueryTimeoutError {
            return t.message.isBlank ? "查询超时（可在 设置 → 数据源 放宽查询超时）" : t.message
        }
        if e is SqlPolicy.SqlPolicyViolation {
            return "SQL 未登记被拒绝（内部错误，已记录日志）"
        }
        if let s = e as? SemanticUnavailableError {
            return s.message.isBlank ? "语义模型未导入" : s.message
        }
        if isConn(e) {
            return "远程库不可达：\(short(e))"
        }
        if let db = e as? DbError {
            return sqlMsg(db.errorCode, db.sqlState, db.message)
        }
        if let mio = e as? MySQLNIO.MySQLError {
            switch mio {
            case .server(let p):
                return sqlMsg(Int(p.errorCode.rawValue), p.sqlState, p.errorMessage)
            case .duplicateEntry(let m):
                return "数据库错误 1062：\(String(m.prefix(60)))"
            case .invalidSyntax(let m):
                return "SQL 语法错误（内部错误，已记录日志）"
            default:
                return "查询失败：\(short(e))"
            }
        }
        return "查询失败：\(short(e))"
    }

    public static func short(_ e: Error) -> String {
        let name = String(describing: type(of: e))
        let msg = String(String(describing: e).prefix(60))
        var s = "\(name): \(msg)"
        while s.hasSuffix(":") || s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    static func sqlMsg(_ errorCode: Int?, _ sqlState: String?, _ message: String) -> String {
        if let st = sqlState, st.hasPrefix("08") { return "与数据库通信中断" }
        switch errorCode {
        case 1045, 1044: return "账号或密码错误（设置 → 数据源）"
        case 1049: return "库名不存在（设置 → 数据源）"
        case 1146: return "表不存在（远程库未同步该数据）"
        case 1054: return "未知列（远程库结构与本版本不一致）"
        case 1064: return "SQL 语法错误（内部错误，已记录日志）"
        default:
            let m = String(message.prefix(60))
            return "数据库错误 \(errorCode ?? -1)：\(m)"
        }
    }

    /// "只有连接级才说不可达"
    public static func isConn(_ e: Error) -> Bool {
        if e is QueryTimeoutError { return false }
        if e is NoNetworkError { return false }
        if e is CancellationError { return false }
        if e is SqlPolicy.SqlPolicyViolation { return false }
        if let db = e as? DbError {
            if let st = db.sqlState, st.hasPrefix("08") { return true }
            if let code = db.errorCode, SEMANTIC_CODES.contains(code) { return false }
            return db.kind == .connection || hasMarker(db.message)
        }
        if let mio = e as? MySQLNIO.MySQLError {
            switch mio {
            case .server(let p):
                // 明确语义错误码: 服务器可达, 不算连接级（先于消息兜底，保持 Android 偏差记录语义）
                if let st = p.sqlState, st.hasPrefix("08") { return true }
                if SEMANTIC_CODES.contains(Int(p.errorCode.rawValue)) { return false }
                return hasMarker(p.errorMessage)
            case .closed, .secureConnectionRequired:
                return true
            case .unsupportedAuthPlugin, .authPluginDataError:
                return false
            default:
                return hasMarker(mio.message)
            }
        }
        let typeName = String(describing: type(of: e))
        if CONN_TYPE_MARKERS.contains(where: { typeName.contains($0) }) { return true }
        return hasMarker(String(describing: e))
    }

    static func hasMarker(_ msg: String) -> Bool {
        MSG_MARKERS.contains { msg.range(of: $0, options: .caseInsensitive) != nil }
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
