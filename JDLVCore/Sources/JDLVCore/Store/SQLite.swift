import Foundation

//
//  SQLite.swift —— sqlite3 C API 薄封装（P5 本地存储层唯一触碰 sqlite 的文件）。
//
//  对齐 Android: 四库各自 SQLiteOpenHelper（IdxDb/ShadowDb/EmbStore 开 WAL+synchronous=NORMAL,
//  LocalStore/PageCache 走默认 journal）; busy_timeout Android 未显式设 → iOS 统一 5000ms
//  （多连接并发写时的防御, 刻意差异, 见移植报告）。
//
//  跨平台策略（本文件是全仓唯一直接绑定 C sqlite/zlib 符号的地方）:
//  - Apple(iOS/macOS): 走系统 `import SQLite3` 模块（SDK 自带 modulemap + libsqlite3.tbd）。
//  - Linux: swift 工具链不提供 SQLite3 modulemap（swift:6.0-noble 实测无）, 且系统只有
//    libsqlite3.so.0 无头文件 → #else 分支用 @_silgen_name 手写同签名 C 绑定, 无头文件依赖;
//    链接需要 libsqlite3.so（libsqlite3-dev 或 ln -s libsqlite3.so.0 libsqlite3.so）。
//  - Package.swift: JDLVCore target linkerSettings = [.linkedLibrary("sqlite3"), .linkedLibrary("z")]
//    （z 供 PageCache.swift 的 gzip 用, 同为 @_silgen_name 手写绑定）。
//
//  线程安全: NSRecursiveLock 串行化全部调用（事务体可重入）; 连接以 SQLITE_OPEN_FULLMUTEX 打开。
//  BLOB 一律 Data。错误一律上抛 StoreError（含 sqlite errmsg / code / sql 原文）。
//

/// 存储层统一错误（含 sqlite errmsg）。
public struct StoreError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String

    public init(code: Int32, message: String, sql: String) {
        self.code = code
        self.message = message
        self.sql = sql
    }

    /// 连接已关闭等非 sqlite 错误
    public static func closed(_ what: String = "") -> StoreError {
        StoreError(code: -1, message: "database closed \(what)", sql: "")
    }

    public var description: String {
        let tail = sql.isEmpty ? "" : " sql=\(sql.prefix(160))"
        return "StoreError(code=\(code), \(message))\(tail)"
    }
}

// MARK: - C 绑定（Apple: 系统 SQLite3 模块; Linux: 手写 @_silgen_name 绑定）

#if canImport(SQLite3)
import SQLite3
#else
// —— Linux 回退: sqlite3 C API 手写绑定（签名与 C 头文件逐字对齐; 无头文件依赖）——
typealias sqlite3_destructor_type = @convention(c) (UnsafeMutableRawPointer?) -> Void

@_silgen_name("sqlite3_open_v2") func sqlite3_open_v2(
    _ filename: UnsafePointer<CChar>?, _ ppDb: UnsafeMutablePointer<OpaquePointer?>?,
    _ flags: CInt, _ zVfs: UnsafePointer<CChar>?) -> CInt
@_silgen_name("sqlite3_close") func sqlite3_close(_ db: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_busy_timeout") func sqlite3_busy_timeout(_ db: OpaquePointer?, _ ms: CInt) -> CInt
@_silgen_name("sqlite3_prepare_v2") func sqlite3_prepare_v2(
    _ db: OpaquePointer?, _ zSql: UnsafePointer<CChar>?, _ nByte: CInt,
    _ ppStmt: UnsafeMutablePointer<OpaquePointer?>?,
    _ pzTail: UnsafePointer<UnsafePointer<CChar>?>?) -> CInt
@_silgen_name("sqlite3_step") func sqlite3_step(_ stmt: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_reset") func sqlite3_reset(_ stmt: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_clear_bindings") func sqlite3_clear_bindings(_ stmt: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_finalize") func sqlite3_finalize(_ stmt: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_bind_int64") func sqlite3_bind_int64(_ stmt: OpaquePointer?, _ idx: CInt, _ value: Int64) -> CInt
@_silgen_name("sqlite3_bind_double") func sqlite3_bind_double(_ stmt: OpaquePointer?, _ idx: CInt, _ value: Double) -> CInt
@_silgen_name("sqlite3_bind_null") func sqlite3_bind_null(_ stmt: OpaquePointer?, _ idx: CInt) -> CInt
@_silgen_name("sqlite3_bind_text") func sqlite3_bind_text(
    _ stmt: OpaquePointer?, _ idx: CInt, _ value: UnsafePointer<CChar>?, _ n: CInt,
    _ destructor: sqlite3_destructor_type?) -> CInt
@_silgen_name("sqlite3_bind_blob") func sqlite3_bind_blob(
    _ stmt: OpaquePointer?, _ idx: CInt, _ value: UnsafeRawPointer?, _ n: CInt,
    _ destructor: sqlite3_destructor_type?) -> CInt
@_silgen_name("sqlite3_column_count") func sqlite3_column_count(_ stmt: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_column_name") func sqlite3_column_name(_ stmt: OpaquePointer?, _ idx: CInt) -> UnsafePointer<CChar>?
@_silgen_name("sqlite3_column_type") func sqlite3_column_type(_ stmt: OpaquePointer?, _ idx: CInt) -> CInt
@_silgen_name("sqlite3_column_int64") func sqlite3_column_int64(_ stmt: OpaquePointer?, _ idx: CInt) -> Int64
@_silgen_name("sqlite3_column_double") func sqlite3_column_double(_ stmt: OpaquePointer?, _ idx: CInt) -> Double
@_silgen_name("sqlite3_column_text") func sqlite3_column_text(_ stmt: OpaquePointer?, _ idx: CInt) -> UnsafePointer<UInt8>?
@_silgen_name("sqlite3_column_blob") func sqlite3_column_blob(_ stmt: OpaquePointer?, _ idx: CInt) -> UnsafeRawPointer?
@_silgen_name("sqlite3_column_bytes") func sqlite3_column_bytes(_ stmt: OpaquePointer?, _ idx: CInt) -> CInt
@_silgen_name("sqlite3_changes") func sqlite3_changes(_ db: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_errcode") func sqlite3_errcode(_ db: OpaquePointer?) -> CInt
@_silgen_name("sqlite3_errmsg") func sqlite3_errmsg(_ db: OpaquePointer?) -> UnsafePointer<CChar>?
#endif

/// 常量自备（k 前缀避免与 Apple 模块导出的 SQLITE_* 重名; 两条分支共用同一套值）。
private let kSQLITE_OK: CInt = 0
private let kSQLITE_ROW: CInt = 100
private let kSQLITE_DONE: CInt = 101
private let kSQLITE_INTEGER: CInt = 1
private let kSQLITE_FLOAT: CInt = 2
private let kSQLITE_TEXT: CInt = 3
private let kSQLITE_BLOB: CInt = 4
private let kSQLITE_NULL: CInt = 5
private let kOPEN_READWRITE: CInt = 0x0000_0002
private let kOPEN_CREATE: CInt = 0x0000_0004
private let kOPEN_FULLMUTEX: CInt = 0x0001_0000

/// SQLITE_TRANSIENT（= 让 sqlite 复制绑定缓冲; C 里是 (void(*)(void*))-1 哨兵值）
private let kSqliteTransient: sqlite3_destructor_type = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 连接封装

/// sqlite3 连接薄封装。方法全部同步 + throws（调用方保证不并发滥用; 内部递归锁兜底）。
public final class SQLite {

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    public let path: String
    private var inTransaction = false

    /// 打开（或创建）库。wal=true: PRAGMA journal_mode=WAL + synchronous=NORMAL
    /// （对齐 Android IdxDb/ShadowDb/EmbStore 的 onConfigure; journal_mode 返回结果行,
    /// 统一走 prepare/step 而非 exec——部分 ROM execSQL 对返回行语句直接抛的教训）。
    /// wal=false: 保持 SQLite 默认 rollback journal（对齐 PageCache/LocalStore 无 onConfigure）。
    public init(path: String, wal: Bool = true) throws {
        self.path = path
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, kOPEN_READWRITE | kOPEN_CREATE | kOPEN_FULLMUTEX, nil)
        guard rc == kSQLITE_OK, let opened = db else {
            let msg = db.flatMap { h in sqlite3_errmsg(h).map { String(cString: $0) } } ?? "open failed"
            if let d = db { sqlite3_close(d) }
            throw StoreError(code: rc, message: msg, sql: path)
        }
        handle = opened
        _ = sqlite3_busy_timeout(opened, 5000)
        if wal {
            try? exec("PRAGMA journal_mode=WAL")
            try? exec("PRAGMA synchronous=NORMAL")
        }
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let h = handle {
            sqlite3_close(h)
            handle = nil
        }
    }

    // MARK: 错误 / 状态

    public func lastError(_ sql: String = "") -> StoreError {
        guard let h = handle else { return .closed(sql) }
        let msg = sqlite3_errmsg(h).map { String(cString: $0) } ?? "unknown"
        return StoreError(code: sqlite3_errcode(h), message: msg, sql: sql)
    }

    /// 最近一条语句修改/插入/删除的行数（sqlite3_changes）
    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return 0 }
        return Int(sqlite3_changes(h))
    }

    // MARK: 执行

    /// 无结果集语句（DDL / PRAGMA / DELETE 等）。有结果行的 PRAGMA 也安全（step 到 DONE）。
    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == kSQLITE_DONE { return }
            if rc == kSQLITE_ROW { continue }   // PRAGMA journal_mode 等带结果行
            throw lastError(sql)
        }
    }

    /// 绑定参数执行（INSERT/UPDATE/DELETE）。返回本语句 changes。
    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue?] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params, sql)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == kSQLITE_DONE { break }
            if rc == kSQLITE_ROW { continue }
            throw lastError(sql)
        }
        guard let h = handle else { return 0 }
        return Int(sqlite3_changes(h))
    }

    /// [String] 参数便捷重载（PruneSql 生成语句的参数形态是 [String]）。
    @discardableResult
    public func run(_ sql: String, _ params: [String]) throws -> Int {
        try run(sql, params.map { SQLValue?.some(.string($0)) })
    }

    /// 查询全部行（列名 → SQLValue）。
    public func query(_ sql: String, _ params: [SQLValue?] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params, sql)
        var rows: [Row] = []
        let n = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == kSQLITE_DONE { break }
            guard rc == kSQLITE_ROW else { throw lastError(sql) }
            var map: [String: SQLValue] = [:]
            var i: CInt = 0
            while i < n {
                let name = sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "c\(i)"
                map[name] = Self.columnValue(stmt, i)
                i += 1
            }
            rows.append(Row(map))
        }
        return rows
    }

    /// 单值查询（无行 → nil）。
    public func scalar(_ sql: String, _ params: [SQLValue?] = []) throws -> SQLValue? {
        try query(sql, params).first.flatMap { row -> SQLValue? in
            row.map.values.first
        }
    }

    /// [String] 参数便捷重载。
    public func scalar(_ sql: String, _ params: [String]) throws -> SQLValue? {
        try scalar(sql, params.map { SQLValue?.some(.string($0)) })
    }

    // MARK: 事务

    /// 事务体: begin → body → commit; body 抛错 → rollback 并上抛。
    /// 嵌套调用（事务体内再调 transaction）合并进外层事务（Android 无此形态, 防御用）。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if inTransaction { return try body() }
        try exec("BEGIN IMMEDIATE")
        inTransaction = true
        do {
            let r = try body()
            try exec("COMMIT")
            inTransaction = false
            return r
        } catch {
            inTransaction = false
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: PRAGMA 助手

    /// 整型 PRAGMA 读取（page_count / page_size / user_version ...）; 失败 0。
    public func pragmaInt(_ name: String) -> Int64 {
        guard let v = try? scalar("PRAGMA \(name)") else { return 0 }
        switch v {
        case .int(let x): return x
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    /// PRAGMA wal_checkpoint(TRUNCATE)（WAL 归零后 usageBytes 口径; 失败静默——对齐 Android runCatching）。
    public func walCheckpointTruncate() {
        try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// 设置 user_version（库版本号）。
    public func setUserVersion(_ v: Int) {
        try? exec("PRAGMA user_version = \(v)")
    }

    // MARK: 内部

    private func prepare(_ sql: String, _ params: [SQLValue?]) throws -> OpaquePointer {
        guard let h = handle else { throw StoreError.closed(sql) }
        var stmt: OpaquePointer?
        let rc = sql.withCString { csql in
            sqlite3_prepare_v2(h, csql, -1, &stmt, nil)
        }
        guard rc == kSQLITE_OK, let s = stmt else {
            if let s = stmt { sqlite3_finalize(s) }
            throw lastError(sql)
        }
        return s
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue?], _ sql: String) throws {
        for (offset, v) in params.enumerated() {
            let idx = CInt(offset + 1)
            let rc: CInt
            switch v {
            case nil, .some(.null):
                rc = sqlite3_bind_null(stmt, idx)
            case .some(.int(let x)):
                rc = sqlite3_bind_int64(stmt, idx, x)
            case .some(.double(let x)):
                rc = sqlite3_bind_double(stmt, idx, x)
            case .some(.bool(let b)):
                rc = sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            case .some(.string(let s)):
                rc = s.withCString { cstr in
                    sqlite3_bind_text(stmt, idx, cstr, CInt(s.utf8.count), kSqliteTransient)
                }
            case .some(.data(let d)):
                rc = Self.bindBlob(stmt, idx, d)
            }
            if rc != kSQLITE_OK { throw lastError(sql) }
        }
    }

    /// BLOB 绑定。空 Data 绑「零长 blob」而非 NULL（NULL 指针 + n=0 会被 sqlite 当 NULL）。
    private static func bindBlob(_ stmt: OpaquePointer, _ idx: CInt, _ d: Data) -> CInt {
        if d.isEmpty {
            var sentinel: UInt8 = 0
            return withUnsafePointer(to: &sentinel) { p in
                sqlite3_bind_blob(stmt, idx, UnsafeRawPointer(p), 0, kSqliteTransient)
            }
        }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            sqlite3_bind_blob(stmt, idx, raw.baseAddress, CInt(d.count), kSqliteTransient)
        }
    }

    private static func columnValue(_ stmt: OpaquePointer, _ i: CInt) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case kSQLITE_INTEGER:
            return .int(sqlite3_column_int64(stmt, i))
        case kSQLITE_FLOAT:
            return .double(sqlite3_column_double(stmt, i))
        case kSQLITE_TEXT:
            guard let p = sqlite3_column_text(stmt, i) else { return .null }
            return .string(String(cString: p))
        case kSQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .data(Data()) }
            return .data(Data(bytes: p, count: n))
        default:
            return .null
        }
    }
}

// MARK: - 文件工具

/// 文件字节数（不存在 → 0）。usageBytes 统计 idx.db-wal 等用。
public func storeFileSize(_ path: String) -> Int64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? NSNumber else { return 0 }
    return size.int64Value
}

/// epoch 毫秒（写时间戳统一口径; Android System.currentTimeMillis() 对应）。
public func storeNowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
