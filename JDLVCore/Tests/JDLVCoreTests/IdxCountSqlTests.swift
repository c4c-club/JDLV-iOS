import Foundation
import XCTest
@testable import JDLVCore

/// B3. IdxCountSqlTest —— 本地"影片数"类 COUNT 与列表同口径（4 用例）。
/// S16-07：计数 SQL 必须与列表同 JOIN 口径；计数必须 JOIN idx_movies
/// （关系表孤儿不计入，禁止只数关系表）。
final class IdxCountSqlTests: XCTestCase {

    private func placeholders(_ sql: String) -> Int {
        sql.filter { $0 == "?" }.count
    }

    /// actorNoTagJoinsMovies：无标签计数 JOIN idx_movies + idx_movie_actors，占位符恰 1 个
    func testActorNoTagJoinsMovies() {
        let sql = IdxCountSql.actorMovieCount(hasTag: false)
        XCTAssertTrue(sql.contains("FROM idx_movies m"))
        XCTAssertTrue(sql.contains("JOIN idx_movie_actors ma ON ma.movie_id = m.id"))
        XCTAssertTrue(sql.contains("WHERE ma.actor_id = ?"))
        XCTAssertEqual(placeholders(sql), 1)
    }

    /// actorTaggedJoinsBothRelations：有标签计数同时 JOIN 两张关系表，占位符恰 2 个
    func testActorTaggedJoinsBothRelations() {
        let sql = IdxCountSql.actorMovieCount(hasTag: true)
        XCTAssertTrue(sql.contains("JOIN idx_movie_actors"))
        XCTAssertTrue(sql.contains("JOIN idx_movie_tags"))
        XCTAssertTrue(sql.contains("mt.tag_id = ?"))
        XCTAssertTrue(sql.contains("ma.actor_id = ?"))
        XCTAssertEqual(placeholders(sql), 2)
    }

    /// tagCountJoinsMovies：标签计数 JOIN idx_movies + idx_movie_tags
    func testTagCountJoinsMovies() {
        let sql = IdxCountSql.TAG_COUNT
        XCTAssertTrue(sql.contains("FROM idx_movies m"))
        XCTAssertTrue(sql.contains("JOIN idx_movie_tags mt ON mt.movie_id = m.id"))
        XCTAssertTrue(sql.contains("WHERE mt.tag_id = ?"))
        XCTAssertEqual(placeholders(sql), 1)
    }

    /// countSqlNeverCountsRelationTableAlone：三个计数 SQL 全部含 FROM idx_movies m
    func testCountSqlNeverCountsRelationTableAlone() {
        let sqls = [IdxCountSql.ACTOR_NO_TAG, IdxCountSql.ACTOR_TAGGED, IdxCountSql.TAG_COUNT]
        for sql in sqls {
            XCTAssertTrue(sql.contains("FROM idx_movies m"), "禁止只数关系表：\(sql)")
        }
    }
}
