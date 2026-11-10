import Foundation
import MySQLNIO

// MARK: - 错误类型

public enum DbErrorKind {
    case connection   // 连接级（refused/timeout/closed/handshake）——可重试、置离线
    case semantic     // 语义级（1064/1146/1054/1044/1045/1049）——不重试
    case timeout      // 语句超时——作废连接，不重试
    case noNetwork    // 系统无网——置离线 30s
}

public struct DbError: Error, CustomStringConvertible {
    public let kind: DbErrorKind
    public let message: String
    public let errorCode: Int?
    public let sqlState: String?

    public init(kind: DbErrorKind, message: String, errorCode: Int? = nil,
                sqlState: String? = nil) {
        self.kind = kind
        self.message = message
        self.errorCode = errorCode
        self.sqlState = sqlState
    }

    public var description: String { message }
}

/// 语句超时（不重试，直接向上层报"查询超时"）
public struct QueryTimeoutError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 无网快速失败
public struct NoNetworkError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 语义模型未导入（Q.SemanticUnavailableException 对应）
public struct SemanticUnavailableError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String = "语义模型未导入") { self.message = message }
    public var description: String { message }
}

// MARK: - EventLoopFuture → async 桥接（带一次性保护的 promise）

func awaitFuture<T>(_ f: EventLoopFuture<T>) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        f.whenComplete { r in
            switch r {
            case .success(let v): cont.resume(returning: v)
            case .failure(let e): cont.resume(throwing: e)
            }
        }
    }
}

/// 一次性结果盒：超时与正常完成竞态时保证 promise 只 resolve 一次
final class OneShot<T> {
    private let lock = NSLock()
    private var fired = false
    private let promise: EventLoopPromise<T>

    init(on el: EventLoop) {
        promise = el.makePromise(of: T.self)
    }

    var futureResult: EventLoopFuture<T> { promise.futureResult }

    /// R9/R3：竞态判定（迟到成功方据此关闭连接）
    var isFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }

    func succeed(_ v: T) {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        lock.unlock()
        promise.succeed(v)
    }

    func fail(_ e: Error) {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        lock.unlock()
        promise.fail(e)
    }
}

/// 超时包装：把 make() 产生的 future 与 event loop 上的定时器竞速。
/// 超时后 future 自身继续跑完（与 Android"语句超时后连接作废"语义一致，调用方负责关连接）。
func raceTimeout<T>(
    _ seconds: Int, on el: EventLoop, _ make: () -> EventLoopFuture<T>
) async throws -> T {
    let box = OneShot<T>(on: el)
    make().whenComplete { r in
        switch r {
        case .success(let v): box.succeed(v)
        case .failure(let e): box.fail(e)
        }
    }
    _ = el.scheduleTask(in: .milliseconds(Int64(seconds) * 1000)) {
        box.fail(QueryTimeoutError("timeout after \(seconds)s"))
    }
    return try await awaitFuture(box.futureResult)
}

// MARK: - 设置

public struct MySQLPoolSettings {
    public var host: String
    public var port: Int
    public var user: String
    public var pass: String
    public var jdbDb: String
    public var shtDb: String
    public var tls: Bool
    public var connectTimeout: Int    // 秒
    public var queryTimeout: Int      // 秒
    /// SOCKS 隧道模式下：连接 host=127.0.0.1:tunnelPort，但 TLS SNI 仍填真实主机
    public var serverHostname: String?

    public init(host: String, port: Int, user: String, pass: String,
                jdbDb: String, shtDb: String, tls: Bool,
                connectTimeout: Int = 5, queryTimeout: Int = 8,
                serverHostname: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.pass = pass
        self.jdbDb = jdbDb
        self.shtDb = shtDb
        self.tls = tls
        self.connectTimeout = connectTimeout
        self.queryTimeout = queryTimeout
        self.serverHostname = serverHostname
    }
}

// MARK: - AsyncSemaphore

public final class AsyncSemaphore {
    private let lock = NSLock()
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ permits: Int) { self.permits = permits }

    public func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if permits > 0 {
                permits -= 1
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    public func release() {
        lock.lock()
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            lock.unlock()
            cont.resume()
        } else {
            permits += 1
            lock.unlock()
        }
    }
}

// MARK: - 连接构建

public enum ConnFactory {
    /// R9/R13：显式白名单（非 jdb/sht 一律类型化错误，不再默认映射 sht）
    public static func databaseName(_ which: String, _ s: MySQLPoolSettings) throws -> String {
        switch which {
        case "jdb": return s.jdbDb
        case "sht": return s.shtDb
        default: throw DbError(kind: .semantic, message: "未知数据源 (which=\(which))")
        }
    }

    static func connect(_ which: String, _ s: MySQLPoolSettings,
                        on group: EventLoopGroup) async throws -> MySQLConnection {
        let db = try databaseName(which, s)
        var tlsConfig: TLSConfiguration?
        if s.tls {
            var c = TLSConfiguration.makeClientConfiguration()
            c.certificateVerification = .none   // 与 Android verifyServerCertificate=false 对齐
            tlsConfig = c
        }
        let el = group.next()
        let addr: SocketAddress
        do {
            addr = try SocketAddress.makeAddressResolvingHost(s.host, port: s.port)
        } catch {
            throw DbError(kind: .connection, message: "地址解析失败: \(s.host):\(s.port)")
        }
        let box = OneShot<MySQLConnection>(on: el)
        // R4：空口令必须发 nil（不发口令），发 "" 会被服务端按「used password: YES」
        // 校验失败（MySQL 8 caching_sha2 空口令账号语义）—— 修复 CI 空口令 root 连接
        let pass: String? = s.pass.isEmpty ? nil : s.pass
        let fut = MySQLConnection.connect(
            to: addr,
            username: s.user,
            database: db,
            password: pass,
            tlsConfiguration: tlsConfig,
            serverHostname: s.tls ? (s.serverHostname ?? s.host) : nil,
            on: el
        )
        fut.whenComplete { r in
            switch r {
            case .success(let c):
                // R9/R3：连接超时已触发 → 迟到成功。OneShot 会忽略该结果，
                // 必须关闭迟到连接（否则 MySQLConnection deinit 撞 assert(!channel.isActive)）
                if box.isFired {
                    MySQLPool.pinned.add(c)
                    Task { [c] in
                        _ = try? await awaitFuture(c.close())
                        MySQLPool.pinned.remove(c)
                    }
                } else {
                    box.succeed(c)
                }
            case .failure(let e): box.fail(e)
            }
        }
        _ = el.scheduleTask(in: .milliseconds(Int64(s.connectTimeout) * 1000)) {
            box.fail(DbError(kind: .connection, message: "连接超时 (\(s.connectTimeout)s)"))
        }
        do {
            return try await awaitFuture(box.futureResult)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

// MARK: - MySQL 池

/// 连接池（对齐 Android DbPool）：每库 3 连接 + 信号量 + 世代号 + 空闲回收。
/// 超时不重试；取消作废连接；连接级失败重试 1 次（共 2 次尝试）；
/// 连接级失败置离线 60s、无网 30s；查询成功/探活成功清该库标记。
public final class MySQLPool {
    public static let POOL_PER_DB = 3
    public static let IDLE_CLOSE_MS: Int64 = 600_000   // 10 分钟（严格大于回收）
    public static let DBS = ["jdb", "sht"]

    public final class Slot {
        let conn: MySQLConnection
        let gen: Int64
        var lastUsed: Int64
        init(conn: MySQLConnection, gen: Int64, lastUsed: Int64) {
            self.conn = conn
            self.gen = gen
            self.lastUsed = lastUsed
        }
    }

    public static let shared = MySQLPool()

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let lock = NSLock()
    private var gen: Int64 = 0
    private var sems: [String: AsyncSemaphore] = [:]
    private var idle: [String: [Slot]] = [:]
    private var created: [String: Int] = [:]

    private let cfgLock = NSLock()
    private var _settingsProvider: (() -> MySQLPoolSettings?)?
    private var _hasNetwork: (() -> Bool)?

    /// 设置提供器（每次取当前设置；A10/R10：锁保护 —— 任意线程读写安全）
    public var settingsProvider: (() -> MySQLPoolSettings?)? {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return _settingsProvider }
        set { cfgLock.lock(); _settingsProvider = newValue; cfgLock.unlock() }
    }
    /// 无网判定注入（App 层用 NWPathMonitor；nil = 视为有网；锁保护）
    public var hasNetwork: (() -> Bool)? {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return _hasNetwork }
        set { cfgLock.lock(); _hasNetwork = newValue; cfgLock.unlock() }
    }

    init() {
        for w in MySQLPool.DBS {
            sems[w] = AsyncSemaphore(MySQLPool.POOL_PER_DB)
            idle[w] = []
            created[w] = 0
        }
    }

    deinit {
        // 只关闭空闲连接。禁止在这里 syncShutdownGracefully：
        // 它会强关在途命令的 channel → MySQLNIO "Statement not closed" 断言 → SIGILL。
        // 在途连接由 deferred close 负责（见 execQuery），进程退出前未落定的由 pinned 钉住防 deinit 断言。
        lock.lock()
        let all = idle.values.flatMap { $0 }
        idle = ["jdb": [], "sht": []]
        lock.unlock()
        for slot in all where !slot.conn.isClosed {
            _ = try? slot.conn.close().wait()
        }
    }

    /// 在途连接钉住池：防止 future 未落定前连接 dealloc 触发 MySQLNIO deinit 断言
    static let pinned = PinnedConns()

    public final class PinnedConns: @unchecked Sendable {
        private let lk = NSLock()
        private var items: [MySQLConnection] = []
        func add(_ c: MySQLConnection) {
            lk.lock(); items.append(c); lk.unlock()
        }
        func remove(_ c: MySQLConnection) {
            lk.lock(); items.removeAll { $0 === c }; lk.unlock()
        }
    }

    // MARK: 借出 / 归还 / 作废

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 借出：FIFO 空闲队列；空闲 >10min / 世代不匹配 / 校验失败 → 关闭换下一个
    private func borrow(_ which: String, _ s: MySQLPoolSettings) async throws -> Slot {
        let now = nowMs()
        while true {
            var cand: Slot? = nil
            lock.lock()
            if var q = idle[which], !q.isEmpty {
                cand = q.removeFirst()
                idle[which] = q
            }
            lock.unlock()
            guard let slot = cand else { break }
            var dead = now - slot.lastUsed > MySQLPool.IDLE_CLOSE_MS
            if !dead { dead = slot.gen != gen }
            if !dead { dead = !(await connValid(slot)) }
            if dead {
                await closeConn(slot)
                lock.lock()
                created[which] = max(0, (created[which] ?? 1) - 1)
                lock.unlock()
                continue
            }
            slot.lastUsed = now
            return slot
        }
        lock.lock()
        created[which] = (created[which] ?? 0) + 1
        let g = gen
        lock.unlock()
        let conn: MySQLConnection
        do {
            conn = try await ConnFactory.connect(which, s, on: group)
        } catch {
            // R9/R6：建连失败必须回滚账目（否则 created 只增不减，与信号量口径漂移）
            lock.lock()
            created[which] = max(0, (created[which] ?? 1) - 1)
            lock.unlock()
            throw error
        }
        return Slot(conn: conn, gen: g, lastUsed: nowMs())
    }

    /// isValid(2) 等价：SELECT 1 短校验（2s），异常视为失效
    /// （R9/R4：pinned 竞速 —— 超时后底层查询落定再关，杜绝在途 simpleQuery 被 close）
    private func connValid(_ slot: Slot) async -> Bool {
        guard !slot.conn.isClosed else { return false }
        do {
            _ = try await MySQLPool.raceQuery(slot.conn, "SELECT 1", timeoutSec: 2)
            return true
        } catch {
            return false
        }
    }

    private func recycle(_ which: String, _ slot: Slot) {
        lock.lock()
        if slot.gen != gen {
            lock.unlock()
            Task { await closeConn(slot) }
            lock.lock()
            created[which] = max(0, (created[which] ?? 1) - 1)
            lock.unlock()
            return
        }
        slot.lastUsed = nowMs()
        idle[which]?.append(slot)
        lock.unlock()
    }

    /// 作废连接（任何异常路径：绝不把"可能仍在用"的连接放回池）
    func closeConn(_ slot: Slot) async {
        guard !slot.conn.isClosed else { return }
        _ = try? await awaitFuture(slot.conn.close())
    }

    // MARK: 查询主流程

    public func query(
        which: String, sql: String, params: [SQLValue?] = [], timeoutSec: Int? = nil
    ) async throws -> [Row] {
        guard let sem = sems[which] else {
            // R9/R13：未知 which → 类型化错误（不再 fatalError）
            throw DbError(kind: .semantic, message: "未知数据源 (which=\(which))")
        }
        try SqlPolicy.guard_(which, sql)
        guard let s = settingsProvider?() else {
            throw DbError(kind: .semantic, message: "数据源未配置")
        }
        // 无网前置：不建连，快速失败
        if !(hasNetwork?() ?? true) {
            OfflineGate.mark(which, ttlMs: 30_000)
            throw NoNetworkError("无网络连接 — 显示已缓存的本地数据")
        }
        let ts = timeoutSec ?? s.queryTimeout
        var attempt = 0
        while true {
            attempt += 1
            await sem.acquire()
            var slot: Slot? = nil
            do {
                slot = try await borrow(which, s)
                let rows = try await execQuery(slot!, sql, params, timeoutSec: ts)
                recycle(which, slot!)
                OfflineGate.clear(which)
                sem.release()
                return rows
            } catch {
                if let slot {
                    // 超时/取消：底层查询仍在途，连接由 execQuery 的 deferred close 关闭
                    let inflight = error is QueryTimeoutError || error is CancellationError
                    if !inflight {
                        await closeConn(slot)
                    }
                    lock.lock()
                    created[which] = max(0, (created[which] ?? 1) - 1)
                    lock.unlock()
                }
                sem.release()
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if error is QueryTimeoutError {
                    // 语句超时不重试（Android 语义：作废连接 + 直接抛）
                    throw QueryTimeoutError("查询超时 (\(ts)s) — 可在设置里放宽查询超时")
                }
                let connLevel = ErrText.isConn(error)
                if !connLevel || attempt >= 2 {
                    if connLevel { OfflineGate.mark(which, ttlMs: 60_000) }
                    throw error
                }
                // 连接级异常重试 1 次（共 2 次尝试）
                try Task.checkCancellation()
            }
        }
    }

    /// 单次执行（超时 = timeoutSec 秒；超时/取消由调用方作废连接）
    private func execQuery(
        _ slot: Slot, _ sql: String, _ params: [SQLValue?], timeoutSec: Int
    ) async throws -> [Row] {
        let conn = slot.conn
        let el = conn.eventLoop
        let box = OneShot<[Row]>(on: el)
        let binds: [MySQLData] = params.map { Self.toMySQLData($0) }
        let fut = conn.query(sql, binds)
        fut.whenComplete { r in
            switch r {
            case .success(let rows): box.succeed(rows.map(Self.normRow))
            case .failure(let e): box.fail(e)
            }
        }
        _ = el.scheduleTask(in: .milliseconds(Int64(timeoutSec) * 1000)) {
            box.fail(QueryTimeoutError("statement timeout \(timeoutSec)s"))
        }
        do {
            return try await withTaskCancellationHandler(operation: {
                try await awaitFuture(box.futureResult)
            }, onCancel: {
                box.fail(CancellationError())
            })
        } catch {
            // 超时/取消时查询仍在服务器端执行：连接必须在底层 future 落定后再关
            // （MySQLNIO 在命令在途时发 COM_QUIT 会触发断言 → SIGILL）。
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

    // MARK: ping / reset

    /// R9/R4：pinned 竞速查询（connValid / ping / 显式探活共用）。
    /// 超时/取消时连接由 pinned 在底层 future 落定后关闭 —— 与 execQuery 同口径。
    static func raceQuery(
        _ conn: MySQLConnection, _ sql: String, timeoutSec: Int
    ) async throws -> [Row] {
        let el = conn.eventLoop
        let box = OneShot<[Row]>(on: el)
        let fut = conn.simpleQuery(sql)
        fut.whenComplete { r in
            switch r {
            case .success(let rows): box.succeed(rows.map(Self.normRow))
            case .failure(let e): box.fail(e)
            }
        }
        _ = el.scheduleTask(in: .milliseconds(Int64(timeoutSec) * 1000)) {
            box.fail(QueryTimeoutError("timeout after \(timeoutSec)s"))
        }
        do {
            return try await awaitFuture(box.futureResult)
        } catch {
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

    /// 探活：一次性短连接（不进池不占信号量）、SELECT 1、2s 超时；成功清该库离线标记
    public func ping(_ which: String) async -> Bool {
        guard hasNetwork?() ?? true else { return false }
        guard let s = settingsProvider?() else { return false }
        let conn: MySQLConnection
        do {
            conn = try await ConnFactory.connect(which, s, on: group)
        } catch {
            return false
        }
        do {
            _ = try await MySQLPool.raceQuery(conn, "SELECT 1", timeoutSec: 2)
            OfflineGate.clear(which)
            _ = try? await awaitFuture(conn.close())   // 正常路径立即关
            return true
        } catch {
            // 超时/取消：raceQuery 已 pin 并在落定后关；其它错误：立即关
            if !(error is QueryTimeoutError) && !(error is CancellationError) {
                _ = try? await awaitFuture(conn.close())
            }
            return false
        }
    }

    // MARK: 显式设置探活（A4/R4：测试连接用草稿直连，不改全局 provider / 不进池）

    /// 显式设置探活结果：真实版本号（SELECT VERSION()）
    public struct PingInfo {
        public var version: String?
        public init(version: String?) { self.version = version }
    }

    /// 按【显式 settings】探活指定库：一次性短连接（不进池不占信号量）、
    /// SELECT VERSION() 取真实版本、2s 超时；成功时清该库离线标记。
    /// 与 ping(which:)（全局 provider）并存：设置页「测试连接」传草稿，运行链路不受影响。
    public func ping(
        which: String, settings: MySQLPoolSettings
    ) async -> Result<PingInfo, Error> {
        guard hasNetwork?() ?? true else {
            return .failure(NoNetworkError("无网络连接 — 显示已缓存的本地数据"))
        }
        let conn: MySQLConnection
        do {
            conn = try await ConnFactory.connect(which, settings, on: group)
        } catch {
            return .failure(error)
        }
        do {
            let rows = try await MySQLPool.raceQuery(conn, "SELECT VERSION()", timeoutSec: 2)
            OfflineGate.clear(which)
            let version = rows.first?.s("VERSION()") ?? ""
            _ = try? await awaitFuture(conn.close())   // 正常路径立即关
            return .success(PingInfo(version: version.isEmpty ? nil : version))
        } catch {
            if !(error is QueryTimeoutError) && !(error is CancellationError) {
                _ = try? await awaitFuture(conn.close())
            }
            return .failure(error)
        }
    }

    /// 全部连接作废（数据源/代理/超时变更）：gen++ + 空闲清空 + 清全部离线标记
    public func resetAll() {
        lock.lock()
        gen += 1
        let all = idle
        idle = ["jdb": [], "sht": []]
        created = ["jdb": 0, "sht": 0]
        lock.unlock()
        for (_, slots) in all {
            for slot in slots {
                Task { await closeConn(slot) }
            }
        }
        OfflineGate.clear()
    }

    // MARK: - MySQLNIO 值转换（对齐 DbPool.norm）

    static func toMySQLData(_ v: SQLValue?) -> MySQLData {
        switch v {
        case nil, .some(.null):
            return MySQLData.null
        case .some(.int(let i)):
            return MySQLData(int: Int(truncatingIfNeeded: i))
        case .some(.double(let d)):
            return MySQLData(double: d)
        case .some(.string(let s)):
            return MySQLData(string: s)
        case .some(.bool(let b)):
            return MySQLData(bool: b)
        case .some(.data(let d)):
            var buf = ByteBufferAllocator().buffer(capacity: d.count)
            buf.writeBytes(d)
            return MySQLData(type: .blob, format: .binary, buffer: buf, isUnsigned: false)
        }
    }

    /// 行规范化（列名用 label；同名列后写覆盖 —— Android LinkedHashMap 语义，
    /// row.column() 只返回首个匹配，必须按位置取值；A10/R10：列序写入 orderedKeys）
    static func normRow(_ row: MySQLRow) -> Row {
        var map: [String: SQLValue] = [:]
        var ordered: [String] = []
        for (i, col) in row.columnDefinitions.enumerated() {
            let data = row.values[i].map {
                MySQLData(
                    type: col.columnType, format: row.format, buffer: $0,
                    isUnsigned: col.flags.contains(.COLUMN_UNSIGNED))
            }
            map[col.name] = normValue(data)
            ordered.append(col.name)
        }
        return Row(map: map, orderedKeys: ordered)
    }

    static func normValue(_ d: MySQLData?) -> SQLValue {
        guard let d else { return .null }
        guard let buf = d.buffer else { return .null }
        switch d.type {
        case .null:
            return .null
        case .tiny, .short, .long, .longlong, .int24, .year:
            return .int(Int64(d.int ?? 0))
        case .decimal, .newdecimal, .float, .double:
            return .double(d.double ?? 0.0)
        case .date, .time, .datetime, .timestamp, .newdate, .timestamp2, .datetime2, .time2:
            // 二进制协议下 string 可能取不到（MySQLTime 表示）——按 Android Timestamp.toString 语义格式化
            if let s = d.string, !s.isEmpty { return .string(s) }
            if let mt = d.time {
                var s = String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                               mt.year ?? 0, mt.month ?? 1, mt.day ?? 1,
                               mt.hour ?? 0, mt.minute ?? 0, mt.second ?? 0)
                if (mt.microsecond ?? 0) > 0 {
                    s += String(format: ".%06d", mt.microsecond ?? 0)
                }
                return .string(s)
            }
            return .string("")
        case .bit:
            return .bool(d.bool ?? false)
        case .blob, .tinyBlob, .mediumBlob, .longBlob, .geometry, .json:
            let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) ?? []
            let data = Data(bytes)
            // ByteArray → UTF-8 String（Android norm 语义）
            if let s = String(data: data, encoding: .utf8) { return .string(s) }
            return .string(d.string ?? "")
        default:
            if buf.readableBytes == 0 { return .string("") }
            return .string(d.string ?? "")
        }
    }
}
