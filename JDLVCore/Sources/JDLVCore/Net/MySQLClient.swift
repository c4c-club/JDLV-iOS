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
        let fut = conn.query(sql, binds)
        fut.whenComplete { r in
            switch r {
            case .success(let rows): box.succeed(rows.map(MySQLPool.normRow))
            case .failure(let e): box.fail(e)
            }
        }
        _ = conn.eventLoop.scheduleTask(
            in: .milliseconds(Int64(ts) * 1000)) {
            box.fail(QueryTimeoutError("statement timeout \(ts)s"))
        }
        do {
            return try await awaitFuture(box.futureResult)
        } catch {
            // R9/R5：与池同口径 —— 超时/取消时连接由 pinned 在底层 future 落定后关闭
            if error is QueryTimeoutError || error is CancellationError {
                MySQLPool.pinned.add(conn)
                fut.whenComplete { [conn] _ in
                    Task {
                        _ = try? await awaitFuture(conn.close())
                        MySQLPool.pinned.remove(conn)
                    }
                }
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
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

    deinit {
        if let conn, !conn.isClosed {
            // R9/R5：deinit 不阻塞等待（close 走 fire-and-forget；正常路径由 close() 完成）
            _ = conn.close()
        }
        conn = nil
        // 不做 group.syncShutdownGracefully（可能强关在途命令 channel → MySQLNIO 断言）
    }
}
