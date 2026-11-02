import Foundation

// P2 依赖 spike：MySQLNIO 编译引用。真实连接/池/超时/取消语义在 P3 实现。

public struct MySQLClientConfig {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var database: String
    public var tls: Bool
    public var connectTimeoutSeconds: Int
    /// TLS SNI/证书校验用的真实主机名（SOCKS 隧道时 host=127.0.0.1，仍填真实主机）
    public var serverHostname: String?

    public init(host: String, port: Int, username: String, password: String,
                database: String, tls: Bool, connectTimeoutSeconds: Int = 5,
                serverHostname: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.serverHostname = serverHostname
    }
}

public enum MySQLErrorKind {
    case connection   // 连接级（refused/timeout/closed/handshake）——可重试、置离线
    case semantic     // 语义级（1064/1146/1054/1044/1045/1049）——不重试
    case timeout      // 语句超时——作废连接，不重试
    case noNetwork    // 系统无网——置离线 30s
}

public struct MySQLError: Error {
    public let kind: MySQLErrorKind
    public let message: String
    public init(kind: MySQLErrorKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// MySQL 客户端（P3 完成实现；本文件仅做依赖 spike 编译引用）。
public final class MySQLClient {
    public let config: MySQLClientConfig

    public init(config: MySQLClientConfig) {
        self.config = config
    }

    #if canImport(MySQLNIO)
    // 编译引用（P3 起真实使用 MySQLConnection/MySQLPool）
    typealias NioConnection = MySQLConnection
    static let nioAvailable = true
    #endif

    /// spike 占位：P3 用 MySQLNIO 实现真实握手与查询
    public func ping() async throws {}
}
