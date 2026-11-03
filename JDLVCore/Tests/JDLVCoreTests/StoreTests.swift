//
//  StoreTests.swift
//  JDLVCoreTests
//
//  P5 本地四库存储层单测（SQLite / LocalStore / IdxDb / ShadowDb / PageCache / EmbStore / Indexer）。
//  对齐 Android: app/src/main/java/com/jdlv/mobile/core/cache/*（docs/_extract/06_store.md）
//               与 data/LocalStore.kt（docs/_extract/13_theme_prefs_models.md §C）。
//
//  Linux 兼容: 全部同步断言（仅 1 例 async 的协议注入用例）; 临时目录用
//  NSTemporaryDirectory() + FileManager（Linux corelibs 可用）; 时间敏感用例
//  通过内部 db 句柄回填 ts/updated_at（确定性, 不依赖时钟）, 仅 TTL 用例 sleep 1.1s。
//

import XCTest
@testable import JDLVCore

final class StoreTests: XCTestCase {

    // MARK: - 工具

    private func tmpDir(_ tag: String) -> String {
        let dir = NSTemporaryDirectory() + "jdlv-store-" + tag + "-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func movie(
        id: String, title: String = "", number: String = "",
        release: String = "2024-01-01", extra: [String: SQLValue] = [:]
    ) -> Row {
        var map: [String: SQLValue] = [
            "id": .string(id),
            "title": .string(title),
            "number": .string(number),
            "release_date": .string(release),
        ]
        for (k, v) in extra { map[k] = v }
        return Row(map)
    }

    private static func thread(
        tid: String, title: String = "", board: String = "", boardName: String = "",
        type: String = "", magnetCount: Int64 = 0
    ) -> Row {
        Row([
            "tid": .string(tid),
            "title": .string(title),
            "board": .string(board),
            "board_name": .string(boardName),
            "type": .string(type),
            "magnet_count": .int(magnetCount),
        ])
    }

    /// 不可压缩伪随机可打印 ASCII（确定性 LCG; 容量裁剪用例需要 size 稳定）
    private static func pseudoRandomString(_ seed: UInt64, _ len: Int) -> String {
        var s = seed
        var out = [UInt8]()
        for _ in 0..<len {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            out.append(32 + UInt8(truncatingIfNeeded: s >> 33) % 95)
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func countTable(_ db: SQLite, _ table: String) throws -> Int64 {
        guard let v = try db.scalar("SELECT COUNT(*) FROM \(table)"),
              case .int(let x) = v else { return 0 }
        return x
    }

    private func tableNames(_ db: SQLite) throws -> Set<String> {
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table'", [])
        return Set(rows.map { $0.s("name") })
    }

    private func indexNames(_ db: SQLite) throws -> Set<String> {
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index'", [])
        return Set(rows.map { $0.s("name") })
    }

    // MARK: - A. SQLite 薄封装（6）

    func test_sqlite_execRunQueryScalar() throws {
        let db = try SQLite(path: tmpDir("core") + "/t.db")
        defer { db.close() }
        try db.exec("CREATE TABLE t(a INTEGER, b TEXT)")
        try db.run("INSERT INTO t(a, b) VALUES(?, ?)", [.int(7), .string("x")])
        let rows = try db.query("SELECT a, b FROM t")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].i("a"), 7)
        XCTAssertEqual(rows[0].s("b"), "x")
        guard case .int(let n)? = try db.scalar("SELECT COUNT(*) FROM t") else {
            return XCTFail()
        }
        XCTAssertEqual(n, 1)
    }

    func test_sqlite_bindRoundtripAllTypes() throws {
        let db = try SQLite(path: tmpDir("core") + "/t.db")
        defer { db.close() }
        try db.exec("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB, bo INTEGER, n TEXT)")
        let blob = Data([0, 1, 2, 255])
        try db.run(
            "INSERT INTO t(i, d, s, b, bo, n) VALUES(?,?,?,?,?,?)",
            [.int(-42), .double(3.5), .string("中文"), .data(blob), .bool(true), .null])
        let r = try db.query("SELECT * FROM t")[0]
        XCTAssertEqual(r.i("i"), -42)
        XCTAssertEqual(r.d("d"), 3.5)
        XCTAssertEqual(r.s("s"), "中文")
        XCTAssertEqual(r["b"], .data(blob))
        XCTAssertEqual(r.b("bo"), true)
        XCTAssertEqual(r["n"], SQLValue.null)
    }

    func test_sqlite_emptyBlobStaysBlob() throws {
        let db = try SQLite(path: tmpDir("core") + "/t.db")
        defer { db.close() }
        try db.exec("CREATE TABLE t(b BLOB)")
        try db.run("INSERT INTO t(b) VALUES(?)", [.data(Data())])
        guard case .data(let blob)? = try db.scalar("SELECT b FROM t") else {
            return XCTFail("空 Data 不应变成 NULL")
        }
        XCTAssertEqual(blob.count, 0)
    }

    func test_sqlite_transactionRollbackOnError() throws {
        let db = try SQLite(path: tmpDir("core") + "/t.db")
        defer { db.close() }
        try db.exec("CREATE TABLE t(a INTEGER)")
        do {
            try db.transaction {
                try db.run("INSERT INTO t(a) VALUES(1)")
                throw StoreError(code: -9, message: "boom", sql: "")
            }
            XCTFail("应上抛")
        } catch { /* 预期 */ }
        guard case .int(let n)? = try db.scalar("SELECT COUNT(*) FROM t") else { return XCTFail() }
        XCTAssertEqual(n, 0, "事务体抛错必须回滚")
        // 嵌套 transaction 合并进外层
        try db.transaction {
            try db.transaction { try db.run("INSERT INTO t(a) VALUES(2)") }
        }
        XCTAssertEqual(try countTable(db, "t"), 1)
    }

    func test_sqlite_changesCounts() throws {
        let db = try SQLite(path: tmpDir("core") + "/t.db")
        defer { db.close() }
        try db.exec("CREATE TABLE t(a INTEGER)")
        try db.run("INSERT INTO t(a) VALUES(1)")
        try db.run("INSERT INTO t(a) VALUES(2)")
        try db.run("INSERT INTO t(a) VALUES(3)")
        let n = try db.run("UPDATE t SET a = 9 WHERE a > 1")
        XCTAssertEqual(n, 2)
        XCTAssertEqual(db.changes, 2)
    }

    func test_sqlite_lastErrorCarriesErrmsg() throws {
        let db = try SQLite(path: tmpDir("core") + "/t.db")
        defer { db.close() }
        XCTAssertThrowsError(try db.exec("SELECT * FROM nope")) { err in
            guard let se = err as? StoreError else { return XCTFail("应为 StoreError") }
            XCTAssertTrue(se.message.contains("no such table"))
            XCTAssertTrue(se.sql.contains("nope"))
        }
    }

    // MARK: - B. LocalStore（jdlv_local.db v1, 10）

    func test_local_ddlBothTables() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        let names = try tableNames(st.db)
        XCTAssertTrue(names.contains("favorites"))
        XCTAssertTrue(names.contains("read_history"))
    }

    func test_local_favToggleTrueThenFalse() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        XCTAssertTrue(try st.favToggle(kind: "movie", itemId: "m1", title: "T1"))
        XCTAssertFalse(try st.favToggle(kind: "movie", itemId: "m1", title: "T1"), "第二次 toggle = 取消收藏")
        XCTAssertEqual(try countTable(st.db, "favorites"), 0)
        XCTAssertTrue(try st.favToggle(kind: "sht", itemId: "m1", title: "T1"), "不同 kind 互不影响")
    }

    func test_local_favIs() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        XCTAssertFalse(try st.favIs(kind: "movie", itemId: "m1"))
        try st.favToggle(kind: "movie", itemId: "m1", title: "T1")
        XCTAssertTrue(try st.favIs(kind: "movie", itemId: "m1"))
    }

    func test_local_favListTsDescAndKindFilter() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        try st.favToggle(kind: "movie", itemId: "a", title: "A")
        try st.favToggle(kind: "movie", itemId: "b", title: "B")
        try st.favToggle(kind: "actor", itemId: "c", title: "C")
        // 回填 ts 保证确定性: a=100, b=300, c=200
        try st.db.run("UPDATE favorites SET ts = 100 WHERE item_id = 'a'")
        try st.db.run("UPDATE favorites SET ts = 300 WHERE item_id = 'b'")
        try st.db.run("UPDATE favorites SET ts = 200 WHERE item_id = 'c'")
        XCTAssertEqual(try st.favList().map { $0.s("id") }, ["b", "c", "a"], "ts DESC 新→旧")
        XCTAssertEqual(try st.favList(kind: "movie").map { $0.s("id") }, ["b", "a"])
        XCTAssertEqual(try st.favList(kind: "actor").map { $0.s("id") }, ["c"])
    }

    func test_local_favListRowKeysKindIdTitleTs() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        try st.favToggle(kind: "movie", itemId: "m1", title: "T1")
        let r = try st.favList().first!
        XCTAssertEqual(r.s("kind"), "movie")
        XCTAssertEqual(r.s("id"), "m1", "行键为 id（非 item_id）")
        XCTAssertEqual(r.s("title"), "T1")
        XCTAssertGreaterThan(r.d("ts"), 1_600_000_000, "ts 为 epoch 秒 REAL")
    }

    func test_local_historyMarkReplaceRefreshes() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        try st.historyMark(kind: "movie", itemId: "m1", title: "old")
        try st.db.run("UPDATE read_history SET ts = 100 WHERE item_id = 'm1'")
        try st.historyMark(kind: "movie", itemId: "m1", title: "new")
        XCTAssertEqual(try countTable(st.db, "read_history"), 1, "REPLACE upsert 不重复")
        let rows = try st.db.query("SELECT title, ts FROM read_history")
        XCTAssertEqual(rows[0].s("title"), "new")
        XCTAssertGreaterThan(rows[0].d("ts"), 100, "重复标记刷新 ts")
    }

    func test_local_historyIs() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        XCTAssertFalse(try st.historyIs(kind: "sht", itemId: "t1"))
        try st.historyMark(kind: "sht", itemId: "t1", title: "TT")
        XCTAssertTrue(try st.historyIs(kind: "sht", itemId: "t1"))
    }

    func test_local_historyAndFavSetSubsets() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        try st.historyMark(kind: "movie", itemId: "a", title: "A")
        try st.historyMark(kind: "movie", itemId: "c", title: "C")
        XCTAssertEqual(try st.historySet(kind: "movie", ids: ["a", "b", "c"]), ["a", "c"])
        XCTAssertEqual(try st.historySet(kind: "movie", ids: []), [])
        XCTAssertTrue(try st.favToggle(kind: "movie", itemId: "b", title: "B"))
        XCTAssertEqual(try st.favSet(kind: "movie", ids: ["a", "b"]), ["b"])
    }

    func test_local_batchSetChunksOver500() throws {
        let st = try LocalStore(directory: tmpDir("local"))
        defer { st.close() }
        // 520 个 id, 标记偶数下标（260 个）→ 跨 2 个 500/块 IN 查询
        var ids: [String] = []
        for i in 0..<520 { ids.append(String(format: "id%03d", i)) }
        for (i, id) in ids.enumerated() where i % 2 == 0 {
            try st.historyMark(kind: "movie", itemId: id, title: id)
        }
        let got = try st.historySet(kind: "movie", ids: ids)
        XCTAssertEqual(got.count, 260)
        XCTAssertTrue(got.contains("id000"))
        XCTAssertTrue(got.contains("id518"))
        XCTAssertFalse(got.contains("id001"))
    }

    // MARK: - C. IdxDb 建库/写入口（16）

    func test_idx_ddlSixTables() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        let names = try tableNames(idb.db)
        for t in ["idx_movies", "idx_threads", "idx_actors",
                  "idx_movie_actors", "idx_movie_tags", "idx_meta"] {
            XCTAssertTrue(names.contains(t), "缺表 \(t)")
        }
    }

    func test_idx_ddlIndexes() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        let names = try indexNames(idb.db)
        for ix in ["i_m_rel", "i_m_num", "i_m_maker", "i_m_series", "i_m_dir", "i_m_pub", "i_m_upd",
                   "i_t_post", "i_t_board", "i_t_upd",
                   "i_a_vid", "i_a_name", "i_ma_actor", "i_mt_tag"] {
            XCTAssertTrue(names.contains(ix), "缺索引 \(ix)")
        }
    }

    func test_idx_userVersion3() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        XCTAssertEqual(idb.db.pragmaInt("user_version"), 3)
    }

    func test_idx_v2UpgradeRebuilds() throws {
        let dir = tmpDir("idxv2")
        let idb1 = try IdxDb(directory: dir)
        idb1.upsertMovies([Self.movie(id: "m1"), Self.movie(id: "m2")])
        idb1.close()
        // 模拟旧版 v2 库
        let raw = try SQLite(path: IdxDb.filePath(in: dir))
        try raw.exec("PRAGMA user_version = 2")
        raw.close()
        let idb2 = try IdxDb(directory: dir)
        defer { idb2.close() }
        XCTAssertEqual(try idb2.countOfExact(table: "idx_movies"), 0, "v2→v3 整库重建, 数据清空")
        XCTAssertEqual(idb2.db.pragmaInt("user_version"), 3)
        let names = try tableNames(idb2.db)
        XCTAssertTrue(names.contains("idx_movie_tags"), "重建后 v3 表齐全")
    }

    func test_idx_v9DowngradeRebuilds() throws {
        let dir = tmpDir("idxv9")
        let idb1 = try IdxDb(directory: dir)
        idb1.upsertMovies([Self.movie(id: "m1")])
        idb1.close()
        let raw = try SQLite(path: IdxDb.filePath(in: dir))
        try raw.exec("PRAGMA user_version = 9")
        raw.close()
        let idb2 = try IdxDb(directory: dir)
        defer { idb2.close() }
        XCTAssertEqual(try idb2.countOfExact(table: "idx_movies"), 0, "降级同样整库重建")
        XCTAssertEqual(idb2.db.pragmaInt("user_version"), 3)
    }

    func test_idx_upsertMoviesInsert() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1", title: "T", number: "abp-1")])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 1)
        let r = try idb.db.query("SELECT * FROM idx_movies WHERE id = 'm1'")[0]
        XCTAssertEqual(r.s("title"), "T")
        XCTAssertEqual(r.s("number"), "abp-1")
        XCTAssertGreaterThan(r.i("updated_at"), 0)
        XCTAssertGreaterThanOrEqual(idb.stats.okCount, 1)
    }

    func test_idx_upsertMoviesMissingFieldsProtected() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1", title: "full", number: "abp-1",
                                     extra: ["number_letter": .string("abp")])])
        // 详情行只有 id+title: 不得把 number/letter 冲掉
        idb.upsertMovies([Row(["id": .string("m1"), "title": .string("detail")])])
        let r = try idb.db.query("SELECT * FROM idx_movies WHERE id = 'm1'")[0]
        XCTAssertEqual(r.s("title"), "detail")
        XCTAssertEqual(r.s("number"), "abp-1", "缺失列不触碰")
        XCTAssertEqual(r.s("letter"), "abp", "缺失列不触碰")
    }

    func test_idx_upsertMoviesNullOverwrites() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1", title: "T", number: "abp-1")])
        // null 也写（远程 NULL 需落库）
        idb.upsertMovies([Row(["id": .string("m1"), "number": SQLValue.null])])
        let r = try idb.db.query("SELECT * FROM idx_movies WHERE id = 'm1'")[0]
        XCTAssertTrue(r.isNull("number"), "containsKey 且值为 null → 写 NULL")
        XCTAssertEqual(r.s("title"), "T")
    }

    func test_idx_upsertMoviesKeyAliases() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", extra: [
                "want_watch_count": .int(11), "magnets_count": .int(22), "number_letter": .string("abp"),
            ]),
            Self.movie(id: "m2", extra: [
                "want": .int(33), "magnets": .int(44), "letter": .string("fc2"),
            ]),
        ])
        let r1 = try idb.db.query("SELECT * FROM idx_movies WHERE id = 'm1'")[0]
        XCTAssertEqual(r1.i("want"), 11)
        XCTAssertEqual(r1.i("magnets"), 22)
        XCTAssertEqual(r1.s("letter"), "abp")
        let r2 = try idb.db.query("SELECT * FROM idx_movies WHERE id = 'm2'")[0]
        XCTAssertEqual(r2.i("want"), 33)
        XCTAssertEqual(r2.s("letter"), "fc2")
    }

    func test_idx_upsertMoviesNumericCoercion() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1", extra: [
            "score": .string("8.5"), "want": .string("123"),
        ])])
        let r = try idb.db.query("SELECT * FROM idx_movies WHERE id = 'm1'")[0]
        XCTAssertEqual(r.d("score"), 8.5, "字符串数值强转 Double")
        XCTAssertEqual(r.i("want"), 123, "字符串数值强转 Long")
        // 数值列的 null → 0.0（Android putIf: (v as? Number) ?: toString()?.toDoubleOrNull() ?: 0.0）
        idb.upsertMovies([Row(["id": .string("m1"), "score": SQLValue.null])])
        let r2 = try idb.db.query("SELECT * FROM idx_movies WHERE id = 'm1'")[0]
        XCTAssertEqual(r2.d("score"), 0.0)
    }

    func test_idx_upsertMoviesEmptyIdSkipped() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "", title: "no-id"), Self.movie(id: "m1")])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 1, "空 id 跳过")
    }

    func test_idx_upsertThreadsAliasArticleWords() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertThreads([Row(["tid": .string("t1"), "article_words": .int(999)])])
        let r = try idb.db.query("SELECT * FROM idx_threads WHERE tid = 't1'")[0]
        XCTAssertEqual(r.i("words"), 999, "article_words → words 别名")
    }

    func test_idx_upsertActorsInsert() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertActors([Row([
            "id": .string("a1"), "name": .string("佐々木あき"),
            "videos_count": .int(50), "merged_into": SQLValue.null,
        ])])
        let r = try idb.db.query("SELECT * FROM idx_actors WHERE id = 'a1'")[0]
        XCTAssertEqual(r.s("name"), "佐々木あき")
        XCTAssertEqual(r.i("videos_count"), 50)
        XCTAssertTrue(r.isNull("merged_into"))
    }

    func test_idx_upsertLinksIgnoreDuplicate() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertLinks([(movieId: "m1", actorId: "a1")])
        idb.upsertLinks([(movieId: "m1", actorId: "a1")])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movie_actors"), 1, "INSERT OR IGNORE")
        idb.upsertLinks([(movieId: "", actorId: "a1")])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movie_actors"), 1, "空 id 剔除")
    }

    func test_idx_upsertTagsInsert() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertTags([(movieId: "m1", tagId: "t1"), (movieId: "m1", tagId: "t2")])
        idb.upsertTags([(movieId: "m1", tagId: "t1")])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movie_tags"), 2)
    }

    func test_idx_replaceMovieTagsRemovesOld() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertTags([(movieId: "m1", tagId: "t1"), (movieId: "m1", tagId: "t2")])
        idb.replaceMovieTags(movieId: "m1", tagIds: ["t3"])
        let tags = try idb.db.query("SELECT tag_id FROM idx_movie_tags ORDER BY tag_id").map { $0.s("tag_id") }
        XCTAssertEqual(tags, ["t3"], "详情 replace 语义: 先删后插")
    }

    // MARK: - C2. IdxDb 计数/裁剪/元数据（12）

    func test_idx_countOfWhitelist() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        XCTAssertEqual(try idb.countOf(table: "idx_meta"), 0, "白名单外 0")
        XCTAssertEqual(try idb.countOf(table: "bogus"), 0)
        idb.upsertMovies([Self.movie(id: "m1")])
        XCTAssertEqual(try idb.countOf(table: "idx_movies"), 1)
    }

    func test_idx_countOfTtlCacheWriteInvalidates() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1"), Self.movie(id: "m2"), Self.movie(id: "m3")])
        XCTAssertEqual(try idb.countOf(table: "idx_movies"), 3)
        // 绕过 API 直插（无失效）→ TTL 内缓存仍 3
        try idb.db.run("INSERT INTO idx_movies(id) VALUES('m9')")
        XCTAssertEqual(try idb.countOf(table: "idx_movies"), 3, "1s TTL 内走缓存")
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertEqual(try idb.countOf(table: "idx_movies"), 4, "TTL 过期重查")
        // 写即失效
        idb.upsertMovies([Self.movie(id: "m4")])
        XCTAssertEqual(try idb.countOf(table: "idx_movies"), 5)
    }

    func test_idx_countOfExactBypassesCache() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1")])
        _ = try idb.countOf(table: "idx_movies")      // 填充缓存
        try idb.db.run("INSERT INTO idx_movies(id) VALUES('m2')")
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 2, "countOfExact 绕过缓存")
        XCTAssertEqual(try idb.countOf(table: "idx_movies"), 1, "缓存仍在 TTL 内")
    }

    func test_idx_countActorsAndActive() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertActors([
            Row(["id": .string("a1"), "name": .string("n1"), "merged_into": SQLValue.null]),
            Row(["id": .string("a2"), "name": .string("n2"), "merged_into": .string("a1")]),
            Row(["id": .string("a3"), "name": .string("n3"), "merged_into": .string("")]),
        ])
        XCTAssertEqual(try idb.countActors(), 3, "countActors = countOf(idx_actors)")
        XCTAssertEqual(try idb.countActorsActive(), 2, "merged_into 非空剔除")
    }

    func test_idx_pruneMoviesNoopBoundary() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        for i in 1...3 {
            idb.upsertMovies([Self.movie(id: "m\(i)", release: String(format: "2000-01-%02d", i))])
        }
        let out = idb.pruneMovies(limit: 10)
        guard case .noop(let bd, let bid) = out else { return XCTFail("应为 Noop: \(out)") }
        XCTAssertEqual(bid, "m1", "Noop boundary = 数据扫描序第一行（只读参考）")
        XCTAssertEqual(bd, "2000-01-01")
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 3)
    }

    func test_idx_pruneMoviesSuccessBoundaryAndOrphans() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        var rows: [Row] = []
        for i in 1...10 {
            rows.append(Self.movie(id: String(format: "m%02d", i),
                                   release: String(format: "2000-01-%02d", i)))
        }
        idb.upsertMovies(rows)
        idb.upsertTags([
            (movieId: "m01", tagId: "t1"), (movieId: "m02", tagId: "t1"),
            (movieId: "m03", tagId: "t1"), (movieId: "m04", tagId: "t1"),
        ])
        idb.upsertLinks([(movieId: "m01", actorId: "a1")])
        let out = idb.pruneMovies(limit: 6)
        guard case .success(let deleted, let bd, let bid) = out else {
            return XCTFail("应为 Success: \(out)")
        }
        XCTAssertEqual(deleted, 4)
        XCTAssertEqual(bd, "2000-01-05", "boundary = 保留窗口最旧行（release_date ASC, id ASC）")
        XCTAssertEqual(bid, "m05")
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 6)
        XCTAssertEqual(try idb.countOfExact(table: "idx_movie_tags"), 0, "被删影片的标签关系清理")
        XCTAssertEqual(try idb.countOfExact(table: "idx_movie_actors"), 0, "被删影片的女优关系清理")
        XCTAssertEqual(idb.orphanReport().tagsOrphans, 0)
    }

    func test_idx_pruneMoviesZeroLimitFailed() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1")])
        guard case .failed(let cause) = idb.pruneMovies(limit: 0) else { return XCTFail() }
        XCTAssertFalse(cause.isEmpty)
        guard case .failed = idb.pruneMovies(limit: -1) else { return XCTFail() }
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 1, "Failed 不删数据")
    }

    func test_idx_pruneThreadsSuccessBoundary() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        var rows: [Row] = []
        for i in 1...10 { rows.append(Self.thread(tid: String(format: "t%02d", i))) }
        idb.upsertThreads(rows)
        let out = idb.pruneThreads(limit: 6)
        guard case .success(let deleted, _, let bid) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(deleted, 4)
        XCTAssertEqual(bid, "t05", "threads 淘汰序 = tid ASC")
        XCTAssertEqual(try idb.countOfExact(table: "idx_threads"), 6)
    }

    func test_idx_metaRoundtrip() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        XCTAssertNil(idb.metaGet("m_phase"))
        idb.metaPut("m_phase", "same")
        XCTAssertEqual(idb.metaGet("m_phase"), "same")
        idb.metaPut("m_phase", "null")
        XCTAssertEqual(idb.metaGet("m_phase"), "null", "CONFLICT_REPLACE")
        idb.metaPutLong("m_done", 1)
        XCTAssertEqual(idb.metaGetLong("m_done"), 1)
        XCTAssertEqual(idb.metaGetLong("missing", 7), 7)
    }

    func test_idx_clearCursorKeepsStatsKeys() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.metaPut("m_phase", "same")
        idb.metaPut("t_tid", "123")
        idb.metaPut("movies_n", "100")     // 统计键, 不清
        idb.clearCursor()
        XCTAssertNil(idb.metaGet("m_phase"))
        XCTAssertNil(idb.metaGet("t_tid"))
        XCTAssertEqual(idb.metaGet("movies_n"), "100")
    }

    func test_idx_clearAll() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1")])
        idb.upsertThreads([Self.thread(tid: "t1")])
        idb.upsertActors([Row(["id": .string("a1")])])
        idb.upsertTags([(movieId: "m1", tagId: "t1")])
        idb.upsertLinks([(movieId: "m1", actorId: "a1")])
        idb.metaPut("m_phase", "same")
        idb.clearAll()
        for t in ["idx_movies", "idx_threads", "idx_actors", "idx_movie_actors", "idx_movie_tags", "idx_meta"] {
            XCTAssertEqual(try countTable(idb.db, t), 0, "\(t) 应清空")
        }
    }

    func test_idx_usageBytesFormula() throws {
        let dir = tmpDir("idxusage")
        let idb = try IdxDb(directory: dir)
        defer { idb.close() }
        var rows: [Row] = []
        for i in 0..<50 { rows.append(Self.movie(id: "m\(i)", title: Self.pseudoRandomString(UInt64(i), 120))) }
        idb.upsertMovies(rows)
        _ = idb.usageBytes(fast: false)   // checkpoint(TRUNCATE) 后统计
        let pages = idb.db.pragmaInt("page_count")
        let size = idb.db.pragmaInt("page_size")
        let wal = storeFileSize(IdxDb.filePath(in: dir) + "-wal")
        XCTAssertEqual(idb.usageBytes(fast: true), UsageMath.total(pages * size, wal),
                       "usageBytes = page_count×page_size + idx.db-wal 文件长")
        XCTAssertGreaterThan(idb.usageBytes(fast: true), 0)
    }

    func test_idx_clearOrphans() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1")])
        idb.upsertTags([(movieId: "m1", tagId: "t1"), (movieId: "mX", tagId: "t1")])
        idb.upsertLinks([(movieId: "mY", actorId: "a1")])
        idb.clearOrphans()
        XCTAssertEqual(try idb.countOfExact(table: "idx_movie_tags"), 1)
        XCTAssertEqual(try idb.countOfExact(table: "idx_movie_actors"), 0)
    }

    // MARK: - D. IdxDb 检索（15）

    func test_idx_searchMoviesTitleMultiWordAnd() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", title: "Blue Spring 中文字幕", number: "abc-1"),
            Self.movie(id: "m2", title: "Red Rose", number: "abc-2"),
        ])
        XCTAssertEqual(try idb.searchMovies(q: "spring 中文", scope: "title", per: 20, offset: 0).count, 1,
                       "多词 AND 子串")
        XCTAssertEqual(try idb.searchMovies(q: "spring missing", scope: "title", per: 20, offset: 0).count, 0)
        XCTAssertEqual(try idb.searchMovies(q: "rose", scope: "title", per: 20, offset: 0).count, 1)
        XCTAssertEqual(try idb.searchMovies(q: "  ", scope: "title", per: 20, offset: 0).count, 0, "空词空页")
    }

    func test_idx_searchMoviesNumberScopeOrderedByNumber() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", number: "abp-999"),
            Self.movie(id: "m2", number: "abp-123"),
            Self.movie(id: "m3", number: "fc2-1"),
        ])
        let rows = try idb.searchMovies(q: "abp", scope: "number", per: 20, offset: 0)
        XCTAssertEqual(rows.map { $0.s("id") }, ["m2", "m1"], "number 子串命中, 按 number ASC")
        XCTAssertEqual(try idb.searchMovies(q: "abp", scope: "letter", per: 20, offset: 0).count, 2,
                       "letter 同 number")
    }

    func test_idx_searchMoviesAllScope() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", title: "blue sea", number: "xyz-1"),
            Self.movie(id: "m2", title: "red sea", number: "abp-9"),
        ])
        let rows = try idb.searchMovies(q: "blue", scope: "all", per: 20, offset: 0)
        XCTAssertEqual(rows.map { $0.s("id") }, ["m1"], "all = title OR number")
        XCTAssertEqual(try idb.searchMovies(q: "abp", scope: "all", per: 20, offset: 0).map { $0.s("id") }, ["m2"])
    }

    func test_idx_searchMoviesLikeEscapeNoWildcard() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", title: "50% off_a"),
            Self.movie(id: "m2", title: "AAA"),
            Self.movie(id: "m3", title: "AXA"),
        ])
        XCTAssertEqual(try idb.searchMovies(q: "50%", scope: "title", per: 20, offset: 0).count, 1,
                       "% 字面命中")
        XCTAssertEqual(try idb.searchMovies(q: "off_a", scope: "title", per: 20, offset: 0).count, 1,
                       "_ 字面命中")
        XCTAssertEqual(try idb.searchMovies(q: "A%A", scope: "title", per: 20, offset: 0).count, 0,
                       "ESCAPE '\\' 后 % 不做通配（否则 AAA/AXA 会被命中）")
    }

    func test_idx_searchMoviesAliasColumns() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1", title: "T", extra: [
            "want_watch_count": .int(11), "magnets_count": .int(22), "number_letter": .string("abp"),
        ])])
        let found = try idb.searchMovies(q: "T", scope: "title", per: 20, offset: 0)
        XCTAssertEqual(found.count, 1)
        guard let r = found.first else { return XCTFail() }
        XCTAssertEqual(r.i("want_watch_count"), 11, "读取侧列名归一 want → want_watch_count")
        XCTAssertEqual(r.i("magnets_count"), 22)
        XCTAssertEqual(r.s("number_letter"), "abp")
        XCTAssertEqual(r.s("release_date"), "2024-01-01")
    }

    func test_idx_countMoviesSameCaliber() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", title: "blue sea"), Self.movie(id: "m2", title: "blue sky"),
        ])
        XCTAssertEqual(try idb.countMovies(q: "blue", scope: "title"), 2)
        XCTAssertEqual(try idb.countMovies(q: "sea", scope: "all"), 1)
        XCTAssertEqual(try idb.countMovies(q: "blue", scope: "bogus"), 0)
    }

    func test_idx_searchActorMoviesExcludesMerged() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", release: "2024-03-01"),
            Self.movie(id: "m2", release: "2024-01-01"),
            Self.movie(id: "m3", release: "2024-02-01"),
        ])
        idb.upsertActors([
            Row(["id": .string("a1"), "name": .string("佐々木あき"), "merged_into": SQLValue.null]),
            Row(["id": .string("a2"), "name": .string("合并女优"), "merged_into": .string("a1")]),
        ])
        idb.upsertLinks([(movieId: "m1", actorId: "a1"), (movieId: "m2", actorId: "a1"),
                         (movieId: "m3", actorId: "a2")])
        let rows = try idb.searchActorMovies(q: "佐々木", page: 1, per: 20)
        XCTAssertEqual(rows.map { $0.s("id") }, ["m1", "m2"],
                       "≤50 女优子集 + merged_into 剔除 + release_date DESC")
        // 分页
        let page2 = try idb.searchActorMovies(q: "佐々木", page: 2, per: 1)
        XCTAssertEqual(page2.map { $0.s("id") }, ["m2"])
    }

    func test_idx_countActorMoviesDistinctMovies() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1")])
        idb.upsertActors([
            Row(["id": .string("a1"), "name": .string("ana")]),
            Row(["id": .string("a2"), "name": .string("ana two")]),
        ])
        idb.upsertLinks([(movieId: "m1", actorId: "a1"), (movieId: "m1", actorId: "a2")])
        XCTAssertEqual(try idb.countActorMovies(q: "ana"), 1, "多女优命中同一影片只计一次")
    }

    func test_idx_searchMoviesByTagPagination() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([
            Self.movie(id: "m1", release: "2024-01-01"), Self.movie(id: "m2", release: "2024-02-01"),
            Self.movie(id: "m3", release: "2024-03-01"),
        ])
        idb.upsertTags([(movieId: "m1", tagId: "t1"), (movieId: "m2", tagId: "t1"), (movieId: "m3", tagId: "t1")])
        XCTAssertEqual(try idb.searchMoviesByTag(tagId: "t1", limit: 2, offset: 0).map { $0.s("id") },
                       ["m3", "m2"], "release_date DESC 分页")
        XCTAssertEqual(try idb.searchMoviesByTag(tagId: "t1", limit: 2, offset: 2).map { $0.s("id") }, ["m1"])
    }

    func test_idx_countMoviesByTagOrphanNotCounted() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertMovies([Self.movie(id: "m1"), Self.movie(id: "m2")])
        idb.upsertTags([(movieId: "m1", tagId: "t1"), (movieId: "m2", tagId: "t1"),
                        (movieId: "mGHOST", tagId: "t1")])   // 孤儿关系
        XCTAssertEqual(try idb.countMoviesByTag(tagId: "t1"), 2, "IdxCountSql.TAG_COUNT: JOIN idx_movies 孤儿不计")
    }

    func test_idx_threadByIdFullRow() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        XCTAssertNil(try idb.threadById(tid: "t1"))
        idb.upsertThreads([Self.thread(tid: "t1", title: "TT", board: "main", boardName: "国产原创",
                                       type: "1", magnetCount: 3)])
        let r = try idb.threadById(tid: "t1")
        XCTAssertEqual(r?.s("title"), "TT")
        XCTAssertEqual(r?.s("board_name"), "国产原创")
        XCTAssertEqual(r?.i("magnet_count"), 3)
    }

    func test_idx_searchThreadsSqlFilters() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertThreads([
            Self.thread(tid: "t1", title: "高清国产", board: "main", boardName: "国产原创", type: "1", magnetCount: 2),
            Self.thread(tid: "t2", title: "高清国产无磁", board: "main", boardName: "国产原创", type: "1", magnetCount: 0),
            Self.thread(tid: "t3", title: "高清欧激", board: "other", boardName: "欧激", type: "2", magnetCount: 5),
        ])
        XCTAssertEqual(try idb.searchThreads(q: "高清 国产", board: "", boardName: "", type: "",
                                             hasMagnet: false, limit: 20, offset: 0).count, 2,
                       "多词 AND")
        XCTAssertEqual(try idb.searchThreads(q: "高清", board: "main", boardName: "", type: "",
                                             hasMagnet: false, limit: 20, offset: 0).count, 2, "board 过滤")
        XCTAssertEqual(try idb.searchThreads(q: "高清", board: "", boardName: "国产原创", type: "",
                                             hasMagnet: false, limit: 20, offset: 0).count, 2, "board_name 过滤")
        XCTAssertEqual(try idb.searchThreads(q: "高清", board: "", boardName: "", type: "2",
                                             hasMagnet: false, limit: 20, offset: 0).count, 1, "type 过滤")
        XCTAssertEqual(try idb.searchThreads(q: "高清", board: "", boardName: "", type: "",
                                             hasMagnet: true, limit: 20, offset: 0).count, 2, "磁力过滤")
    }

    func test_idx_threadsBySortWhitelistAsc() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertThreads([
            Self.thread(tid: "t3", title: "a"), Self.thread(tid: "t1", title: "b"), Self.thread(tid: "t2", title: "c"),
        ])
        // post_date 全部相同 → tid DESC 兜底
        XCTAssertEqual(try idb.threadsBy(sort: "post_date", asc: false, limit: 20, offset: 0).map { $0.s("tid") },
                       ["t3", "t2", "t1"])
        XCTAssertEqual(try idb.threadsBy(sort: "tid", asc: true, limit: 20, offset: 0).map { $0.s("tid") },
                       ["t1", "t2", "t3"])
        XCTAssertEqual(try idb.threadsBy(sort: "bogus", asc: false, limit: 20, offset: 0).map { $0.s("tid") },
                       ["t3", "t2", "t1"], "白名单外回退 post_date")
    }

    func test_idx_threadsByClamps() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        idb.upsertThreads([Self.thread(tid: "t1"), Self.thread(tid: "t2"), Self.thread(tid: "t3")])
        XCTAssertEqual(try idb.threadsBy(sort: "tid", asc: true, limit: 0, offset: -5).map { $0.s("tid") },
                       ["t1"], "limit→1, offset→0")
        XCTAssertEqual(try idb.threadsBy(sort: "tid", asc: true, limit: 9999, offset: 1).map { $0.s("tid") },
                       ["t2", "t3"], "limit 钳 500, offset 正常")
    }

    func test_idx_localReadyThreshold() throws {
        let idb = try IdxDb(directory: tmpDir("idx"))
        defer { idb.close() }
        try idb.db.transaction {
            for i in 0..<9_999 {
                try idb.db.run("INSERT INTO idx_movies(id) VALUES(?)", [.string("m\(i)")])
            }
        }
        XCTAssertFalse(idb.localReady(), "<1 万行不就绪")
        idb.upsertMovies([Self.movie(id: "m-final")])   // 写即失效 countOf 缓存 → 10000
        XCTAssertTrue(idb.localReady(), "countOf(idx_movies) >= 10000 即就绪")
    }

    func test_idxSearchable_injectJdbSearchLocalSearch() async throws {
        let dir = tmpDir("idxinject")
        let idb = try IdxDb(directory: dir)
        defer { idb.close(); JdbSearch.idx = nil }
        try idb.db.transaction {
            for i in 0..<9_999 {
                try idb.db.run("INSERT INTO idx_movies(id, title, number, release_date) VALUES(?,?,?,?)",
                               [.string("m\(i)"), .string("blue ocean \(i)"),
                                .string("abp\(i)"), .string("2024-01-01")])
            }
        }
        idb.upsertMovies([Self.movie(id: "m-final", title: "blue ocean final", number: "abp-final",
                                     extra: ["want_watch_count": .int(88)])])
        let idx: IdxSearchable = idb
        JdbSearch.idx = idx
        XCTAssertTrue(JdbSearch.localReady(), "协议经 JdbSearch.idx 注入后 localReady 生效")
        let page = try await JdbSearch.searchLocalIdx(q: "blue ocean final", scope: "title", page: 1, per: 20)
        XCTAssertEqual(page.served, "local")
        XCTAssertEqual(page.items.first?.s("id"), "m-final")
        XCTAssertEqual(page.items.first?.i("want_watch_count"), 88, "检索行走归一列")
        XCTAssertEqual(page.items.first?.s("number_letter"), "", "无 letter 列时空串")
        let count = await JdbSearch.countLocalIdx(q: "blue ocean final", scope: "title")
        XCTAssertGreaterThanOrEqual(count, 1)
        // 协议方法直调
        XCTAssertEqual(try idx.countOf(table: "idx_movies"), 10_000)
        XCTAssertEqual(try idx.threadById(tid: "x"), nil)
    }

    // MARK: - E. ShadowDb（shadow.db v6, 12）

    func test_shadow_ddlTablesNoFts() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        let names = try tableNames(sh.db)
        for t in ["movies_shadow", "threads_shadow", "actors_shadow", "articles_shadow",
                  "magnets_local", "recent_queries", "kv"] {
            XCTAssertTrue(names.contains(t), "缺表 \(t)")
        }
        XCTAssertFalse(names.contains("movies_fts"), "iOS v6 不建 FTS 虚表（ShadowFts 停用）")
        XCTAssertFalse(names.contains("threads_fts"), "")
        XCTAssertEqual(sh.db.pragmaInt("user_version"), 6)
    }

    func test_shadow_upsertMoviesFullReplace() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        try sh.upsertMovies([Self.movie(id: "m1", title: "v1", extra: ["cover_url": .string("c1")])])
        try sh.upsertMovies([Row(["id": .string("m1"), "title": .string("v2")])])
        XCTAssertEqual(try sh.count("movies_shadow"), 1, "CONFLICT_REPLACE 无重复")
        let r = try sh.db.query("SELECT * FROM movies_shadow WHERE id = 'm1'")[0]
        XCTAssertEqual(r.s("title"), "v2")
        XCTAssertTrue(r.isNull("cover"), "整行 REPLACE: 未提供的列被重置（无缺失字段保护, 与 IdxDb 双语义）")
    }

    func test_shadow_movieByIdNormColumns() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        try sh.upsertMovies([Self.movie(id: "m1", title: "T", extra: [
            "cover": .string("c1"), "want": .int(5), "magnets": .int(7),
        ])])
        let r = try sh.movieById("m1")
        XCTAssertEqual(r?.s("cover_url"), "c1", "normMovie: cover_url ← cover")
        XCTAssertEqual(r?.i("want_watch_count"), 5)
        XCTAssertEqual(r?.i("magnets_count"), 7)
        XCTAssertNil(try sh.movieById("nope"))
    }

    func test_shadow_movieDetailMagnetsReplaceAndLink() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        try sh.upsertMovieDetail(
            Self.movie(id: "m1", title: "T"),
            tags: [Row(["tag_id": .string("t1")])],
            actors: [Row(["actor_id": .string("a1")])],
            magnets: [Row(["hash": .string("H1"), "name": .string("n1"), "size": .string("1G")])])
        var mags = try sh.db.query("SELECT * FROM magnets_local WHERE movie_id = 'm1'")
        XCTAssertEqual(mags.count, 1)
        XCTAssertEqual(mags[0].s("link"), "magnet:?xt=urn:btih:H1", "link 兜底拼 hash")
        XCTAssertEqual(mags[0].s("tid"), "")
        // 详情全量快照: 第二次替换 magnets
        try sh.upsertMovieDetail(
            Self.movie(id: "m1", title: "T"),
            tags: [], actors: [], magnets: [Row(["hash": .string("H2"), "link": .string("magnet:x")])])
        mags = try sh.db.query("SELECT * FROM magnets_local WHERE movie_id = 'm1'")
        XCTAssertEqual(mags.count, 1)
        XCTAssertEqual(mags[0].s("hash"), "H2")
        XCTAssertEqual(mags[0].s("link"), "magnet:x", "远程 link 原值优先")
        // actors_json / tags_json: 第二次详情未带 → 整行 REPLACE 置空（ShadowDb 无缺失字段保护）
        let row = try sh.movieById("m1")!
        XCTAssertTrue(row.isNull("actors_json"))
        XCTAssertTrue(row.isNull("tags_json"))
    }

    func test_shadow_movieByIdMagnetsJson() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        try sh.upsertMovieDetail(
            Self.movie(id: "m1", title: "T"),
            tags: [Row(["tag_id": .string("t1"), "tag_name": .string("字幕")])],
            actors: [Row(["actor_id": .string("a1"), "name": .string("あき")])],
            magnets: [Row(["hash": .string("H1")])])
        let r = try sh.movieById("m1")!
        XCTAssertTrue(r.s("tags_json").contains("字幕"))
        XCTAssertTrue(r.s("actors_json").contains("あき"))
        XCTAssertTrue(r.s("magnets").contains("H1"), "magnets 以 JSON 字符串回读")
    }

    func test_shadow_threadByIdFullRowWithEmptyLists() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        XCTAssertNil(try sh.threadById(tid: "t1"))
        try sh.upsertThreadDetail(
            Row(["tid": .string("t1"), "title": .string("TT"), "board": .string("main"),
                 "post_date": .string("2024-01-01"), "magnet_count": .int(1)]),
            magnets: [Row(["hash": .string("H9")])])
        let r = try sh.threadById(tid: "t1")
        XCTAssertEqual(r?.s("title"), "TT")
        XCTAssertTrue(r!.s("magnets").contains("H9"), "magnets 回读")
        XCTAssertEqual(r?["ed2k"], .string("[]"), "补空 ed2k/images/videos/blocks")
        XCTAssertEqual(r?["images"], .string("[]"))
        XCTAssertEqual(r?["videos"], .string("[]"))
        XCTAssertEqual(r?["blocks"], .string("[]"))
        // ShtShadowLike 注入
        let shadowLike: ShtShadowLike = sh
        XCTAssertEqual(try shadowLike.threadById(tid: "t1")?.s("tid"), "t1")
    }

    func test_shadow_pruneLruKeepsNewest() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        for i in 1...6 {
            try sh.upsertMovies([Self.movie(id: "m\(i)", title: "t\(i)")])
            try sh.upsertThreads([Row(["tid": .string("t\(i)"), "title": .string("tt\(i)")])])
        }
        for i in 1...6 {
            try sh.db.run("UPDATE movies_shadow SET updated_at = ? WHERE id = ?",
                          [.int(Int64(i)), .string("m\(i)")])
            try sh.db.run("UPDATE threads_shadow SET updated_at = ? WHERE tid = ?",
                          [.int(Int64(i)), .string("t\(i)")])
        }
        sh.prune(5, 5)   // Indexer 详情落盘尾部参数
        XCTAssertEqual(try sh.count("movies_shadow"), 5, "LRU 5000 上限语义（测试用 5）")
        XCTAssertEqual(try sh.count("threads_shadow"), 5)
        XCTAssertNil(try sh.movieById("m1"), "updated_at ASC 淘汰最旧")
        XCTAssertNotNil(try sh.movieById("m6"))
        XCTAssertNil(try sh.threadById(tid: "t1"))
    }

    func test_shadow_recentQueriesMax12Order() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        for i in 0..<14 { try sh.addRecentQuery("q\(i)") }
        // 同毫秒写入的 ts 并列, 裁剪发生在他处 → 先回填唯一 ts 再触发一次裁剪（确定性）
        let present = try sh.db.query("SELECT q FROM recent_queries").map { $0.s("q") }
        XCTAssertEqual(present.count, 12, "addRecentQuery 已裁到 12")
        for (idx, q) in present.enumerated() {
            try sh.db.run("UPDATE recent_queries SET ts = ? WHERE q = ?",
                          [.int(Int64(idx + 1)), .string(q)])
        }
        try sh.addRecentQuery("qNEW")
        let qs = try sh.recentQueries()
        XCTAssertEqual(qs.count, 12, "上限 12")
        XCTAssertEqual(qs.first, "qNEW", "ts DESC 最新在前")
        XCTAssertFalse(qs.contains(present[0]), "ts 最旧者被裁")
        XCTAssertTrue(qs.contains(present[11]))
    }

    func test_shadow_addRecentQueryBlankIgnored() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        try sh.addRecentQuery("   ")
        XCTAssertEqual(try sh.recentQueries().count, 0)
        try sh.addRecentQuery("  高清  ")
        XCTAssertEqual(try sh.recentQueries(), ["高清"], "trim 后入库")
        try sh.addRecentQuery("高清")
        XCTAssertEqual(try sh.recentQueries().count, 1, "q 主键 REPLACE 去重")
    }

    func test_shadow_usageBytesAtLeastPageSize() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        try sh.upsertMovies([Self.movie(id: "m1")])
        let bytes = sh.usageBytes()
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(bytes, sh.db.pragmaInt("page_count") * sh.db.pragmaInt("page_size"),
                       "checkpoint(TRUNCATE) 后 page_count×page_size 口径")
    }

    func test_shadow_clearKeepsRecentAndKv() throws {
        let sh = try ShadowDb(directory: tmpDir("shadow"))
        defer { sh.close() }
        try sh.upsertMovies([Self.movie(id: "m1")])
        try sh.upsertThreads([Row(["tid": .string("t1")])])
        try sh.upsertActors([Row(["id": .string("a1")])])
        try sh.upsertArticles([Row(["id": .string("ar1")])])
        try sh.addRecentQuery("q1")
        try sh.kvSet("k", "v")
        try sh.clear()
        XCTAssertEqual(try sh.count("movies_shadow"), 0)
        XCTAssertEqual(try sh.count("threads_shadow"), 0)
        XCTAssertEqual(try sh.count("actors_shadow"), 0)
        XCTAssertEqual(try sh.count("articles_shadow"), 0)
        XCTAssertEqual(try sh.count("magnets_local"), 0)
        XCTAssertEqual(try sh.recentQueries(), ["q1"], "clear 不动 recent_queries/kv")
        XCTAssertEqual(try sh.kvGet("k"), "v")
        XCTAssertEqual(try sh.kvGet("nope"), nil)
    }

    func test_shadow_v5UpgradeRebuilds() throws {
        let dir = tmpDir("shadowv5")
        let sh1 = try ShadowDb(directory: dir)
        try sh1.upsertMovies([Self.movie(id: "m1")])
        sh1.close()
        let raw = try SQLite(path: ShadowDb.filePath(in: dir))
        try raw.exec("PRAGMA user_version = 5")
        raw.close()
        let sh2 = try ShadowDb(directory: dir)
        defer { sh2.close() }
        XCTAssertEqual(try sh2.count("movies_shadow"), 0, "v5→v6 整库重建")
        XCTAssertEqual(sh2.db.pragmaInt("user_version"), 6)
    }

    // MARK: - F. PageCache（page_cache.db v1, 11）

    func test_page_ddl() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        XCTAssertTrue(try tableNames(pc.db).contains("page_cache"))
        XCTAssertEqual(pc.db.pragmaInt("user_version"), 1)
        let jm = try pc.db.query("PRAGMA journal_mode")[0]
        XCTAssertEqual(jm.s("journal_mode"), "delete", "page_cache 不开 WAL（默认 rollback journal）")
    }

    func test_page_putGetRoundtrip() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        try pc.put(key: "k", json: "中文内容 hello")
        XCTAssertEqual(try pc.get(key: "k", ttlMinutes: 10), "中文内容 hello")
        XCTAssertEqual(try pc.stale(key: "k"), "中文内容 hello")
        // Any payload → JSON（字典键序不定 → 回读解析断言）
        try pc.put(key: "obj", payload: ["a": 1, "b": "x"])
        let objData = (try pc.stale(key: "obj") ?? "").data(using: .utf8) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: objData)) as? [String: Any]
        XCTAssertEqual(obj?["a"] as? Int, 1)
        XCTAssertEqual(obj?["b"] as? String, "x")
        // 标量 payload → JSON 字符串（含引号）
        try pc.put(key: "s", payload: "hello")
        XCTAssertEqual(try pc.stale(key: "s"), "\"hello\"")
        XCTAssertNil(try pc.get(key: "nope", ttlMinutes: 10))
    }

    func test_page_gzipHeaderMagicAndRoundtrip() throws {
        let raw = Data(String(repeating: "hello gzip 世界 123 ", count: 20).utf8)
        let gz = try PageCache.gzip(raw)
        XCTAssertEqual([UInt8](gz.prefix(2)), [0x1f, 0x8b], "gzip 头 0x1f8b")
        XCTAssertEqual(try PageCache.gunzip(gz), raw)
        XCTAssertLessThan(gz.count, raw.count, "重复内容可压缩")
        // 空 payload
        XCTAssertEqual(try PageCache.gunzip(try PageCache.gzip(Data())), Data())
    }

    func test_page_gzipLargeMultichunk() throws {
        // ~600KB 重复文本 → 压缩后解压跨多个 64KB 输出块
        let raw = String(repeating: "0123456789 abcdefghijklmnopqrstuvwxyz ", count: 15_000)
        let data = Data(raw.utf8)
        let gz = try PageCache.gzip(data)
        XCTAssertGreaterThan(data.count, 128 * 1024)
        XCTAssertEqual(try PageCache.gunzip(gz), data)
    }

    func test_page_sizeColumnIsCompressedBytes() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        let json = String(repeating: "compressible ", count: 100)
        try pc.put(key: "k", json: json)
        let row = try pc.db.query("SELECT payload, size FROM page_cache WHERE key = 'k'")[0]
        guard case .data(let blob)? = row["payload"] else { return XCTFail() }
        XCTAssertEqual(blob.prefix(2).map { $0 }, [0x1f, 0x8b])
        XCTAssertEqual(row.i("size"), Int64(blob.count), "size = gzip 后字节")
        XCTAssertEqual(try pc.usageBytes(), Int64(blob.count), "usageBytes = SUM(size)")
        XCTAssertEqual(try pc.count(), 1)
    }

    func test_page_ttlExpiredAndStale() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        try pc.put(key: "k", json: "v")
        try pc.db.run("UPDATE page_cache SET ts = ? WHERE key = 'k'",
                      [.int(storeNowMs() - 2 * 3_600_000)])   // 2h 前
        XCTAssertNil(try pc.get(key: "k", ttlMinutes: 60), "超 TTL → nil（行保留）")
        XCTAssertEqual(try pc.stale(key: "k"), "v", "stale 无视 TTL")
        XCTAssertEqual(try pc.count(), 1)
        XCTAssertEqual(try pc.get(key: "k", ttlMinutes: 0), "v", "ttl=0 = stale 语义")
        XCTAssertEqual(try pc.stale(key: "k"), "v")
    }

    func test_page_corruptSelfHeal() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        try pc.put(key: "k", json: "v")
        try pc.db.run("UPDATE page_cache SET payload = ? WHERE key = 'k'",
                      [.data(Data([0x12, 0x34, 0x56, 0x78, 0x9a]))])
        XCTAssertNil(try pc.get(key: "k", ttlMinutes: 10), "解压失败 → nil")
        XCTAssertEqual(try pc.count(), 0, "corrupt 行删除自愈")
    }

    func test_page_hitsIncrement() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        try pc.put(key: "k", json: "v")
        _ = try pc.get(key: "k", ttlMinutes: 10)
        _ = try pc.get(key: "k", ttlMinutes: 10)
        guard case .int(let hits)? = try pc.db.scalar("SELECT hits FROM page_cache WHERE key = 'k'") else {
            return XCTFail()
        }
        XCTAssertEqual(hits, 2)
    }

    func test_page_pruneToTargetOldestFirst() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        // 5 条相同 payload（gzip 后等长 σ, 确定性）; 回填 ts 升序 k0 最旧
        let json = Self.pseudoRandomString(7, 400)
        for i in 0..<5 { try pc.put(key: "k\(i)", json: json) }
        for i in 0..<5 {
            try pc.db.run("UPDATE page_cache SET ts = ? WHERE key = ?",
                          [.int(Int64(i)), .string("k\(i)")])
        }
        guard case .int(let sigma)? = try pc.db.scalar("SELECT size FROM page_cache WHERE key = 'k0'") else {
            return XCTFail()
        }
        // budget 使 target = floor(budget*8/10) 落在 (2σ, 3σ] → 精确淘汰 3 条（ts ASC 最早 3 条）
        pc.budgetBytes = 3 * sigma + 50
        pc.prune()
        XCTAssertEqual(try pc.count(), 2, "淘汰到 80% 目标")
        XCTAssertEqual(try pc.usageBytes(), 2 * sigma)
        XCTAssertNil(try pc.stale(key: "k0"), "ts ASC 最先淘汰")
        XCTAssertNil(try pc.stale(key: "k1"), "")
        XCTAssertNil(try pc.stale(key: "k2"), "")
        XCTAssertEqual(try pc.stale(key: "k3"), json)
        XCTAssertEqual(try pc.stale(key: "k4"), json)
    }

    func test_page_putOverwriteSameKey() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        try pc.put(key: "k", json: "v1")
        try pc.put(key: "k", json: "v2")
        XCTAssertEqual(try pc.count(), 1, "INSERT OR REPLACE")
        XCTAssertEqual(try pc.stale(key: "k"), "v2")
    }

    func test_page_clearDisk() throws {
        let pc = try PageCache(directory: tmpDir("page"))
        defer { pc.close() }
        try pc.put(key: "k1", json: "v1")
        try pc.put(key: "k2", json: "v2")
        try pc.clearDisk()
        XCTAssertEqual(try pc.count(), 0)
        XCTAssertNil(try pc.stale(key: "k1"))
    }

    // MARK: - G. EmbStore（embs.db v1, 9）

    func test_emb_ddlEmbsAndKv() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        let names = try tableNames(es.db)
        XCTAssertTrue(names.contains("embs"))
        XCTAssertTrue(names.contains("kv"), "★ Android 缺 kv 表 bug 已修复: onCreate 同时建 kv")
        XCTAssertEqual(es.db.pragmaInt("user_version"), 1)
    }

    func test_emb_putAllGetExistingRoundtrip() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        let v1 = Data([1, 2, 3, 4])
        let v2 = Data([5, 6, 7, 8])
        try es.putAll([11: v1, 22: v2], dim: 4, fp: "fp1")
        let got = try es.getExisting([11, 22, 33])
        XCTAssertEqual(got[11]?.emb, v1)
        XCTAssertEqual(got[22]?.emb, v2)
        XCTAssertNil(got[33])
        XCTAssertEqual(got[11]?.dim, 4)
        XCTAssertEqual(got[11]?.ver, "fp1")
        XCTAssertGreaterThan(got[11]?.ts ?? 0, 0)
    }

    func test_emb_getExistingChunksOver900() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        var vecs: [Int64: Data] = [:]
        for i in 0..<1000 { vecs[Int64(i)] = Data([UInt8(i % 255), 1, 2, 3]) }
        try es.putAll(vecs, dim: 4, fp: nil)
        let tids = (0..<1000).map { Int64($0) }
        let got = try es.getExisting(tids)
        XCTAssertEqual(got.count, 1000, "900/批分块查询全覆盖")
        XCTAssertEqual(got[999]?.emb, Data([UInt8(999 % 255), 1, 2, 3]))
    }

    func test_emb_dimQuery() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        XCTAssertNil(try es.dim(), "表空 nil")
        try es.putAll([1: Data(repeating: 9, count: 384)], dim: 384, fp: nil)
        XCTAssertEqual(try es.dim(), 384)
    }

    func test_emb_syncModelFpLifecycle() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        XCTAssertTrue(try es.syncModelFp("fp1"), "首次 = 变化")
        try es.putAll([1: Data([1])], dim: 1, fp: "fp1")
        XCTAssertFalse(try es.syncModelFp("fp1"), "相同 = false")
        XCTAssertTrue(try es.syncModelFp("fp2"), "换模型 = true")
        XCTAssertEqual(try es.count(), 0, "换模型旧向量全清")
        XCTAssertNil(try es.modelFp(), "clear 连 model_fp 一起清（调用方重新 putAll）")
    }

    func test_emb_modelFpAfterPutAll() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        try es.putAll([1: Data([1])], dim: 1, fp: "abc")
        XCTAssertEqual(try es.modelFp(), "abc", "putAll 落 kv.model_fp")
        try es.putAll([2: Data([2])], dim: 1, fp: nil)
        XCTAssertEqual(try es.modelFp(), "abc", "fp=nil 不覆盖")
    }

    func test_emb_pruneOverBudgetClears() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        var vecs: [Int64: Data] = [:]
        for i in 0..<20 { vecs[Int64(i)] = Data((0..<100).map { UInt8(($0 + i) % 255) }) }
        try es.putAll(vecs, dim: 100, fp: nil)
        let before = try es.count()
        XCTAssertEqual(before, 20)
        es.maxBytes = 1000   // page ≥ 4096 > 1000 → victims = (total-900)/448+1000 ≥ 全部
        try es.prune()
        XCTAssertEqual(try es.count(), 0, "超预算按 ts ASC 淘汰（Android 公式 +1000 批量删）")
    }

    func test_emb_maxBytesZeroUnlimited() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        es.maxBytes = 0   // 0 = 不限
        try es.putAll([1: Data([1]), 2: Data([2])], dim: 1, fp: nil)
        XCTAssertEqual(try es.count(), 2, "maxBytes=0 → prune no-op")
    }

    func test_emb_clearRemovesVectorsAndFp() throws {
        let es = try EmbStore(directory: tmpDir("emb"))
        defer { es.close() }
        try es.putAll([1: Data([1])], dim: 1, fp: "fp1")
        try es.clear()
        XCTAssertEqual(try es.count(), 0)
        XCTAssertNil(try es.modelFp())
        XCTAssertEqual(try countTable(es.db, "kv"), 0)
    }

    // MARK: - H. Indexer（写入单点, 5）

    func test_indexer_disabledNoWrite() throws {
        let idb = try IdxDb(directory: tmpDir("ix"))
        defer { idb.close() }
        let sh = try ShadowDb(directory: tmpDir("ix"))
        defer { sh.close() }
        let ix = Indexer(idxDb: idb, shadowDb: sh)
        ix.upsertMovieRows([Self.movie(id: "m1")])
        ix.upsertThreadRows([Self.thread(tid: "t1")])
        ix.upsertActorRows([Row(["id": .string("a1")])])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 0, "enabled=false 不落盘")
        XCTAssertEqual(try sh.count("movies_shadow"), 0)
    }

    func test_indexer_enabledWritesIdx() throws {
        let idb = try IdxDb(directory: tmpDir("ix"))
        defer { idb.close() }
        let sh = try ShadowDb(directory: tmpDir("ix"))
        defer { sh.close() }
        let ix = Indexer(idxDb: idb, shadowDb: sh)
        ix.enabled = true
        ix.upsertMovieRows([Self.movie(id: "m1"), Self.movie(id: "m2")])
        ix.upsertMovieRow(Self.movie(id: "m3"))
        ix.upsertThreadRows([Self.thread(tid: "t1")])
        ix.upsertActorRows([Row(["id": .string("a1")])])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 3)
        XCTAssertEqual(try idb.countOfExact(table: "idx_threads"), 1)
        XCTAssertEqual(try idb.countOfExact(table: "idx_actors"), 1)
        XCTAssertEqual(try sh.count("movies_shadow"), 0, "fullMode=false 列表只写 IdxDb")
    }

    func test_indexer_fullModeDualWrite() throws {
        let idb = try IdxDb(directory: tmpDir("ix"))
        defer { idb.close() }
        let sh = try ShadowDb(directory: tmpDir("ix"))
        defer { sh.close() }
        let ix = Indexer(idxDb: idb, shadowDb: sh)
        ix.enabled = true
        ix.fullMode = true   // Android shadowMode == 0
        ix.upsertMovieRows([Self.movie(id: "m1", title: "T", extra: ["cover_url": .string("c")])])
        XCTAssertEqual(try sh.count("movies_shadow"), 1, "fullMode 双写 ShadowDb")
        XCTAssertEqual(try sh.movieById("m1")?.s("cover_url"), "c")
    }

    func test_indexer_movieDetailDualWriteAndReplace() throws {
        let idb = try IdxDb(directory: tmpDir("ix"))
        defer { idb.close() }
        let sh = try ShadowDb(directory: tmpDir("ix"))
        defer { sh.close() }
        let ix = Indexer(idxDb: idb, shadowDb: sh)
        ix.enabled = true
        let m = Self.movie(id: "m1", title: "T")
        ix.upsertMovieDetail(
            m,
            tags: [Row(["tag_id": .string("t1")]), Row(["tag_id": .string("t2")])],
            actors: [Row(["actor_id": .string("a1")])],
            magnets: [Row(["hash": .string("H1")])])
        XCTAssertEqual(try idb.countOfExact(table: "idx_movies"), 1, "详情同时写 IdxDb")
        XCTAssertEqual(try sh.count("movies_shadow"), 1, "详情写 ShadowDb")
        XCTAssertEqual(try sh.count("magnets_local"), 1)
        XCTAssertEqual(try idb.countMoviesByTag(tagId: "t1"), 1)
        XCTAssertEqual(try idb.countMoviesByTag(tagId: "t2"), 1)
        // 第二次详情（远程删除了 t1/t2 → replace 语义不得残留）
        ix.upsertMovieDetail(
            m, tags: [Row(["tag_id": .string("t3")])], actors: [],
            magnets: [Row(["hash": .string("H2")])])
        XCTAssertEqual(try idb.countMoviesByTag(tagId: "t1"), 0, "关系 replace: 旧标签清理")
        XCTAssertEqual(try idb.countMoviesByTag(tagId: "t3"), 1)
        XCTAssertEqual(try sh.count("magnets_local"), 1)
        // 帖子详情
        ix.upsertThreadDetail(
            Row(["tid": .string("t1"), "title": .string("tt")]),
            magnets: [Row(["hash": .string("H9")])])
        XCTAssertEqual(try idb.countOfExact(table: "idx_threads"), 1)
        XCTAssertNotNil(try sh.threadById(tid: "t1"))
    }

    func test_indexer_statsFailWhenDbClosed() throws {
        let idb = try IdxDb(directory: tmpDir("ix"))
        idb.db.close()
        let ix = Indexer(idxDb: idb, shadowDb: nil)
        ix.enabled = true
        ix.upsertMovieRows([Self.movie(id: "m1")])   // 失败静默, 不抛
        XCTAssertGreaterThanOrEqual(idb.stats.failCount, 1, "写失败打点 IdxWriteStats")
        XCTAssertFalse(idb.stats.lastError.isEmpty)
        XCTAssertEqual(ix.stats.failCount, 0, "IdxDb 侧失败记在 IdxDb.stats")
        idb.close()
    }
}
