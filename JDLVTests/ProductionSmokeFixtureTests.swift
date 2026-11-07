import XCTest
@testable import JDLV
import JDLVCore

//
//  ProductionSmokeFixtureTests.swift —— R8 冒烟 fixture 准备（R-V2 前置）。
//
//  CI ios job 的 Test 阶段【先跑单测 bundle 后跑 UI bundle】，本用例在真实 MySQL 上
//  重建 jdlv_app_it 的冒烟 schema/种子（标题「冒烟影片 S001/S002」—— 刻意区别于
//  demo 的「演示影片 NNN」，ProductionSmokeUITests 据此断言非 demo 数据）。
//  本地无 fixture env → XCTSkip。
//
//  DDL/DML 仅作用于测试自建 fixture 库（与 Core 集成测试同口径：临时关闭
//  SqlPolicy.enforce，用后立即恢复）；生产远程库仍只读、不受影响。
//

final class ProductionSmokeFixtureTests: XCTestCase {

    func testCreateSmokeFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JDLV_TEST_MYSQL_HOST"] else {
            throw XCTSkip("本地无 MySQL fixture（CI ios job 注入 JDLV_TEST_MYSQL_*）")
        }
        let port = Int(env["JDLV_TEST_MYSQL_PORT"] ?? "3306") ?? 3306
        let user = env["JDLV_TEST_MYSQL_USER"] ?? "root"
        let pass = env["JDLV_TEST_MYSQL_PASS"] ?? ""

        var s = AppSettings()
        s.remoteHost = host
        s.remotePort = String(port)
        s.remoteUser = user
        s.remotePass = pass
        s.remoteJdb = "jdlv_app_it"
        s.remoteSht = "jdlv_app_it"
        s.dbSsl = false
        s.connectTimeout = 5
        s.queryTimeout = 8
        AppBootstrap.box.update(s)
        AppBootstrap.injectRuntime()

        SqlPolicy.setEnforceForTesting(false)
        defer { SqlPolicy.setEnforceForTesting(true) }

        for stmt in Self.ddl() {
            _ = try await Db.query("jdb", stmt)
        }
        for stmt in Self.seed() {
            _ = try await Db.query("jdb", stmt)
        }

        // 幂等复跑：表已存在也必须可用（fixture 不 DROP，保证 UI bundle 拿到同一份）
        let rows = try await Db.query(
            "jdb", "select title from movies where number = 'S001'")
        XCTAssertEqual(rows.first?.s("title"), "冒烟影片 S001", "冒烟种子必须就位")
    }

    // 与 Core 集成测试 fixture 同构的子集（Q 层所需表）；种子标题为冒烟专用
    static func ddl() -> [String] {
        [
            "CREATE TABLE IF NOT EXISTS movies (id VARCHAR(32) PRIMARY KEY, number VARCHAR(64), " +
                "title VARCHAR(255), release_date VARCHAR(20), year INT, score DECIMAL(4,1), " +
                "want_watch_count INT, magnets_count INT, number_letter VARCHAR(8), " +
                "cover_url TEXT, has_cnsub TINYINT, can_play TINYINT, maker_id VARCHAR(32), " +
                "maker_name VARCHAR(128), series_id VARCHAR(32), director_id VARCHAR(32), " +
                "publisher_id VARCHAR(32))",
            "CREATE TABLE IF NOT EXISTS movie_tags (movie_id VARCHAR(32), tag_id VARCHAR(32), " +
                "tag_name VARCHAR(128), PRIMARY KEY(movie_id, tag_id))",
            "CREATE TABLE IF NOT EXISTS movie_actors (movie_id VARCHAR(32), actor_id VARCHAR(32), " +
                "actor_name VARCHAR(190), PRIMARY KEY(movie_id, actor_id))",
            "CREATE TABLE IF NOT EXISTS actors (id VARCHAR(32) PRIMARY KEY, name VARCHAR(190), " +
                "gender INT, merged_into VARCHAR(32))",
        ]
    }

    static func seed() -> [String] {
        [
            "INSERT INTO movies (id, number, title, release_date, year, score, want_watch_count, " +
                "magnets_count, number_letter, cover_url, has_cnsub, can_play, maker_id, maker_name) " +
                "VALUES ('sm01','S001','冒烟影片 S001','2026-11-01',2026,8.8,66,2,'S',NULL,1,0,'smk','冒烟片商') " +
                "ON DUPLICATE KEY UPDATE title=VALUES(title), release_date=VALUES(release_date)",
            "INSERT INTO movies (id, number, title, release_date, year, score, want_watch_count, " +
                "magnets_count, number_letter, cover_url, has_cnsub, can_play, maker_id, maker_name) " +
                "VALUES ('sm02','S002','冒烟影片 S002','2026-10-15',2026,7.7,33,1,'S',NULL,0,1,'smk','冒烟片商') " +
                "ON DUPLICATE KEY UPDATE title=VALUES(title), release_date=VALUES(release_date)",
            "INSERT INTO movie_tags (movie_id, tag_id, tag_name) VALUES ('sm01','st1','冒烟标签') " +
                "ON DUPLICATE KEY UPDATE tag_name=VALUES(tag_name)",
            "INSERT INTO movie_actors (movie_id, actor_id, actor_name) VALUES ('sm01','sa1','冒烟女优') " +
                "ON DUPLICATE KEY UPDATE actor_name=VALUES(actor_name)",
            "INSERT INTO actors (id, name, gender) VALUES ('sa1','冒烟女优',0) " +
                "ON DUPLICATE KEY UPDATE name=VALUES(name)",
        ]
    }
}
