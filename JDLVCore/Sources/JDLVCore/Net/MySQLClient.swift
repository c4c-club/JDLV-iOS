import Foundation
import MySQLNIO

// 单连接客户端（集成测试 / 探活专用）。生产查询走 MySQLPool。

public final class MySQLClient {
    public let settings: MySQLPoolSettings
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var conn: MySQLConnection?

    public init(settings: MySQLPoolSettings) {
        self.settings = settings
    }

    public func connect(_ which: String = "jdb") async throws {
        conn = try await ConnFactory.connect(which, settings, on: group)
    }

    public func query(_ sql: String, _ params: [SQLValue?] = [], timeoutSec: Int? = nil)
        async throws -> [Row] {
        guard let conn else {
            throw DbError(kind: .connection, message: "not connected")
        }
        let binds: [MySQLData] = params.map { MySQLPool.toMySQLData($0) }
        let ts = timeoutSec ?? settings.queryTimeout
        let box = OneShot<[Row]>(on: conn.eventLoop)
        conn.query(sql, binds).whenComplete { r in
            switch r {
            case .success(let rows): box.succeed(rows.map(MySQLPool.normRow))
            case .failure(let e): box.fail(e)
            }
        }
        _ = conn.eventLoop.scheduleTask(
            in: .milliseconds(Int64(ts) * 1000)) {
            box.fail(QueryTimeoutError("statement timeout \(ts)s"))
        }
        return try await awaitFuture(box.futureResult)
    }

    public func simpleQuery(_ sql: String) async throws -> [Row] {
        guard let conn else {
            throw DbError(kind: .connection, message: "not connected")
        }
        return try await awaitFuture(conn.simpleQuery(sql)).map { MySQLPool.normRow($0) }
    }

    public func close() async {
        if let conn {
            _ = try? await awaitFuture(conn.close())
        }
        conn = nil
    }

    public var isClosed: Bool { conn?.isClosed ?? true }
}
