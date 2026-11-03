import Foundation

//
//  PageCache —— 页缓存 + gzip（page_cache.db v1）。
//  对齐 Android app/src/main/java/com/jdlv/mobile/core/cache/PageCache.kt
//  （提取对照: docs/_extract/06_store.md §3, DDL/算法/参数逐字）。
//
//  要点:
//  - DDL 逐字; ★ 无 onConfigure → 默认 rollback journal, 不开 WAL（四库中唯一, 原样保留差异）。
//  - put: json → gzip(UTF-8) → INSERT OR REPLACE（ttl 恒 0, size = gzip 后字节数）→ prune()。
//  - get: 磁盘命中 → gunzip; 解压失败即删除该行（corrupt 自愈）并返回 nil;
//    ttlMinutes > 0 且 now - ts > ttl*60s → 过期返回 nil（行保留, 对齐 Android）;
//    命中后 hits = hits + 1。
//  - 磁盘预算 64MB; 超限按 ts ASC 淘汰到 budgetBytes*8/10（80%）。
//  - usageBytes = SELECT SUM(size)（payload 压缩字节总和, 非 DB 文件大小）。
//  - gzip: 手写 zlib 绑定（@_silgen_name; 系统 libz 由 Package.swift .linkedLibrary("z") 提供）。
//    ★ 刻意差异（与报告一致）: Android 用 java.util.zip.GZIPOutputStream; iOS 无 Foundation gzip
//    （Linux 上 NSData gzip 不可用、无 zlib.h 头文件）→ 手写 z_stream + deflateInit2_(windowBits=15+16)
//    产出标准 gzip 流（头 0x1f8b）; inflate 用 windowBits=15+32 自动识别 gzip/zlib。
//  - 内存 LRU 8MB 层暂不移植（任务约定先只做磁盘层, 刻意差异）。
//
public final class PageCache {

    public static let DB_NAME = "page_cache.db"
    public static let DB_VERSION = 1

    /// DDL（逐字）
    public static let DDL =
        "CREATE TABLE IF NOT EXISTS page_cache(" +
        "key TEXT PRIMARY KEY, payload BLOB NOT NULL, ts INTEGER NOT NULL, " +
        "ttl INTEGER NOT NULL DEFAULT 0, hits INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL)"

    /// 磁盘预算 64MB（默认, 全仓无覆盖点 → 恒默认）
    public var budgetBytes: Int64 = 64 * 1024 * 1024

    /// internal: 测试（@testable）回填 ts / 检查 payload 字节用
    let db: SQLite

    public init(directory: String) throws {
        db = try SQLite(path: Self.filePath(in: directory), wal: false)   // 不开 WAL
        try db.exec(Self.DDL)
        let v = db.pragmaInt("user_version")
        if v != 0 && v != Int64(Self.DB_VERSION) {
            try? db.exec("DROP TABLE IF EXISTS page_cache")   // onUpgrade → DROP + onCreate
            try db.exec(Self.DDL)
        }
        db.setUserVersion(Self.DB_VERSION)
    }

    public static func filePath(in directory: String) -> String {
        directory.hasSuffix("/") ? directory + DB_NAME : directory + "/" + DB_NAME
    }

    public func close() { db.close() }

    // MARK: - 写

    /// put: gzip(json) 落库; ts = now 毫秒; ttl 恒 0; size = gzip 后字节; 写后 prune()。
    public func put(key: String, json: String) throws {
        let blob = try Self.gzip(Data(json.utf8))
        try db.run(
            "INSERT OR REPLACE INTO page_cache(key, payload, ts, ttl, hits, size) VALUES(?,?,?,?,0,?)",
            [.string(key), .data(blob), .int(storeNowMs()), .int(0), .int(Int64(blob.count))])
        prune()
    }

    /// Any payload → JSON 串（对齐 Android ser(payload).toString()）。
    public func put(key: String, payload: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        guard let json = String(data: data, encoding: .utf8) else {
            throw StoreError(code: -1, message: "payload json utf8 失败", sql: "")
        }
        try put(key: key, json: json)
    }

    // MARK: - 读

    /// TTL 语义: ttlMinutes > 0 且 now - ts > ttl*60_000 → 过期 nil（行保留）。
    /// 解压失败 → 删除该行返回 nil（corrupt 自愈）。命中 → hits+1。
    public func get(key: String, ttlMinutes: Int) throws -> String? {
        guard let row = try db.query(
            "SELECT payload, ts FROM page_cache WHERE key = ?", [.string(key)]).first else { return nil }
        if ttlMinutes > 0 && storeNowMs() - row.i("ts") > Int64(ttlMinutes) * 60_000 {
            return nil
        }
        let json: String
        do {
            guard case .data(let blob)? = row["payload"] else {
                throw StoreError(code: -1, message: "payload 不是 BLOB", sql: "")
            }
            json = try Self.gunzipString(blob)
        } catch {
            try? db.run("DELETE FROM page_cache WHERE key = ?", [.string(key)])
            return nil
        }
        try? db.run("UPDATE page_cache SET hits = hits + 1 WHERE key = ?", [.string(key)])
        return json
    }

    /// 旧缓存无视 TTL（SWR 回退 / 离线渲染）。
    public func stale(key: String) throws -> String? {
        try get(key: key, ttlMinutes: 0)
    }

    // MARK: - 容量

    /// 容量预算: SUM(size)（压缩字节）超 budgetBytes → 按 ts ASC 逐条累计淘汰到 80%。
    public func prune() {
        guard budgetBytes > 0 else { return }
        let total = sumSize()
        if total <= budgetBytes { return }
        let target = budgetBytes * 8 / 10
        var freed: Int64 = 0
        var victims: [String] = []
        if let rows = try? db.query("SELECT key, size FROM page_cache ORDER BY ts ASC") {
            for r in rows {
                if total - freed <= target { break }
                victims.append(r.s("key"))
                freed += r.i("size")
            }
        }
        for k in victims {
            try? db.run("DELETE FROM page_cache WHERE key = ?", [.string(k)])
        }
    }

    /// 设置页显示口径: SUM(size) = payload 压缩字节总和（非 DB 文件大小, 与 WAL/-shm 无关）。
    public func usageBytes() -> Int64 {
        sumSize()
    }

    public func count() -> Int64 {
        guard let v = try? db.scalar("SELECT COUNT(*) FROM page_cache"),
              case .int(let x) = v else { return 0 }
        return x
    }

    /// mem.evictAll() + DELETE FROM page_cache（内存层未移植 → 只清磁盘）。
    public func clearDisk() throws {
        try db.run("DELETE FROM page_cache")
    }

    private func sumSize() -> Int64 {
        guard let v = try? db.scalar("SELECT SUM(size) FROM page_cache"),
              case .int(let x) = v else { return 0 }
        return x
    }

    // MARK: - gzip（手写 zlib 绑定）

    // z_stream 手写布局（C zlib.h 逐字段对齐; uLong 在 Linux/macOS = 8 字节, Win64 = 4 字节）
    #if os(Windows)
    private typealias zULong = CUnsignedInt
    #else
    private typealias zULong = CUnsignedLong
    #endif

    private struct ZStream {
        var next_in: UnsafePointer<UInt8>? = nil
        var avail_in: CUnsignedInt = 0
        var total_in: zULong = 0
        var next_out: UnsafeMutablePointer<UInt8>? = nil
        var avail_out: CUnsignedInt = 0
        var total_out: zULong = 0
        var msg: UnsafePointer<CChar>? = nil
        var state: OpaquePointer? = nil
        var zalloc: OpaquePointer? = nil      // alloc_func; nil = zlib 默认分配
        var zfree: OpaquePointer? = nil       // free_func; nil = zlib 默认释放
        var opaque: UnsafeMutableRawPointer? = nil
        var data_type: CInt = 0
        var adler: zULong = 0
        var reserved: zULong = 0
    }

    // zlib 版本探针只比对首字符（'1'）; stream_size 必须等于本平台 sizeof(z_stream)
    private static let ZLIB_VERSION = "1.2.11"

    @_silgen_name("deflateInit2_") private static func zDeflateInit2(
        _ strm: UnsafeMutablePointer<ZStream>, _ level: CInt, _ method: CInt,
        _ windowBits: CInt, _ memLevel: CInt, _ strategy: CInt,
        _ version: UnsafePointer<CChar>?, _ streamSize: CInt) -> CInt
    @_silgen_name("deflate") private static func zDeflate(
        _ strm: UnsafeMutablePointer<ZStream>, _ flush: CInt) -> CInt
    @_silgen_name("deflateEnd") private static func zDeflateEnd(
        _ strm: UnsafeMutablePointer<ZStream>) -> CInt
    @_silgen_name("deflateBound") private static func zDeflateBound(
        _ strm: UnsafeMutablePointer<ZStream>, _ sourceLen: zULong) -> zULong
    @_silgen_name("inflateInit2_") private static func zInflateInit2(
        _ strm: UnsafeMutablePointer<ZStream>, _ windowBits: CInt,
        _ version: UnsafePointer<CChar>?, _ streamSize: CInt) -> CInt
    @_silgen_name("inflate") private static func zInflate(
        _ strm: UnsafeMutablePointer<ZStream>, _ flush: CInt) -> CInt
    @_silgen_name("inflateEnd") private static func zInflateEnd(
        _ strm: UnsafeMutablePointer<ZStream>) -> CInt

    private static let Z_OK: CInt = 0
    private static let Z_STREAM_END: CInt = 1
    private static let Z_BUF_ERROR: CInt = -5
    private static let Z_NO_FLUSH: CInt = 0
    private static let Z_FINISH: CInt = 4
    private static let Z_DEFLATED: CInt = 8
    private static let Z_DEFAULT_COMPRESSION: CInt = -1
    private static let Z_DEFAULT_STRATEGY: CInt = 0
    private static let Z_MEM_LEVEL: CInt = 8
    private static let GZIP_WINDOW: CInt = 15 + 16   // gzip 包装（头 0x1f8b）
    private static let AUTO_WINDOW: CInt = 15 + 32   // 自动识别 gzip/zlib

    /// gzip 压缩（标准 gzip 流: 0x1f8b 头 + deflate + crc32/isize 尾, 由 zlib windowBits=15+16 生成）。
    static func gzip(_ input: Data) throws -> Data {
        var stream = ZStream()
        var rc = zDeflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, GZIP_WINDOW,
                               Z_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                               CInt(MemoryLayout<ZStream>.size))
        guard rc == Z_OK else {
            throw StoreError(code: rc, message: "deflateInit2_ failed", sql: "")
        }
        defer { zDeflateEnd(&stream) }
        var bytes = [UInt8](input)
        let bound = Int(zDeflateBound(&stream, zULong(max(bytes.count, 1)))) + 64
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: bound)
        defer { out.deallocate() }
        var produced = 0
        rc = bytes.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress.map { UnsafePointer($0) }
            stream.avail_in = CUnsignedInt(inBuf.count)
            stream.next_out = out
            stream.avail_out = CUnsignedInt(bound)
            let rc = zDeflate(&stream, Z_FINISH)
            produced = bound - Int(stream.avail_out)
            return rc
        }
        guard rc == Z_STREAM_END else {
            throw StoreError(code: rc, message: "deflate(Z_FINISH) failed", sql: "")
        }
        return Data(bytes: out, count: produced)
    }

    /// gzip 解压（windowBits=15+32 自动识别 gzip/zlib; 失败抛错 —— 调用方删行自愈）。
    static func gunzip(_ input: Data) throws -> Data {
        var stream = ZStream()
        var rc = zInflateInit2(&stream, AUTO_WINDOW, ZLIB_VERSION,
                               CInt(MemoryLayout<ZStream>.size))
        guard rc == Z_OK else {
            throw StoreError(code: rc, message: "inflateInit2_ failed", sql: "")
        }
        defer { zInflateEnd(&stream) }
        var bytes = [UInt8](input)
        var out = Data()
        let chunk = 65_536
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { outBuf.deallocate() }
        try bytes.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress.map { UnsafePointer($0) }
            stream.avail_in = CUnsignedInt(inBuf.count)
            while true {
                stream.next_out = outBuf
                stream.avail_out = CUnsignedInt(chunk)
                let before = stream.total_out
                rc = zInflate(&stream, Z_NO_FLUSH)
                let produced = Int(stream.total_out - before)
                if produced > 0 { out.append(outBuf, count: produced) }
                if rc == Z_STREAM_END { return }
                if rc == Z_OK {
                    // 无输入且无产出 = 流被截断（corrupt）
                    if stream.avail_in == 0 && produced == 0 {
                        throw StoreError(code: rc, message: "truncated gzip stream", sql: "")
                    }
                    continue
                }
                if rc == Z_BUF_ERROR {
                    // 输出缓冲满 → 下一轮; 无输入 = 截断
                    if stream.avail_in == 0 {
                        throw StoreError(code: rc, message: "truncated gzip stream", sql: "")
                    }
                    continue
                }
                throw StoreError(code: rc, message: "inflate failed: \(stream.msg.map { String(cString: $0) } ?? "")", sql: "")
            }
        }
        return out
    }

    static func gunzipString(_ input: Data) throws -> String {
        let raw = try gunzip(input)
        guard let s = String(data: raw, encoding: .utf8) else {
            throw StoreError(code: -1, message: "gunzip 结果非 UTF-8", sql: "")
        }
        return s
    }
}
