import Foundation
import XCTest
@testable import JDLVCore

/// B1. ActorTagTotalTest —— 演员×标签 计数 SQL/参数/排序（7 用例）。
/// 对应 Android `core/search/ActorTagSql`：演员详情页"TA 的作品 / 标签"聚合，
/// 远程与本地计数 SQL 形状锁定（count 与 items 完全同口径）。
final class ActorTagTotalTests: XCTestCase {

    /// plainCountHasNoTagCondition：无标签计数不 join tag 表，且等于 COUNT_PLAIN
    func testPlainCountHasNoTagCondition() {
        let sql = ActorTagSql.remoteCount(tagged: false)
        XCTAssertEqual(sql, ActorTagSql.COUNT_PLAIN)
        XCTAssertFalse(sql.contains("movie_tags"), "无标签计数不应引用 tag 表：\(sql)")
        XCTAssertTrue(sql.contains("actor_id = ?"))
    }

    /// taggedCountJoinsMoviesAndTags：有标签计数 JOIN movies + tags 两个条件都在
    func testTaggedCountJoinsMoviesAndTags() {
        let sql = ActorTagSql.remoteCount(tagged: true)
        XCTAssertTrue(sql.contains("JOIN movies m ON m.id = ma.movie_id"))
        XCTAssertTrue(sql.contains("tag_id = ?"))
        XCTAssertTrue(sql.contains("ma.actor_id = ?"))
    }

    /// plainParamsOnlyActor：无 tag 只传 actor 一个参数
    func testPlainParamsOnlyActor() {
        XCTAssertEqual(ActorTagSql.remoteParams("000k", ""), ["000k"])
    }

    /// taggedParamsActorThenTag：参数顺序 actor → tag
    func testTaggedParamsActorThenTag() {
        XCTAssertEqual(ActorTagSql.remoteParams("000k", "123"), ["000k", "123"])
    }

    /// remoteTagOrderHasTagIdTiebreaker：远程聚合 tiebreaker 按 tag_id，
    /// 绝不含 tag_name（防同 tag 多历史名跨页重复）
    func testRemoteTagOrderHasTagIdTiebreaker() {
        XCTAssertTrue(ActorTagSql.REMOTE_TAG_ORDER.contains("tag_id ASC"))
        XCTAssertTrue(ActorTagSql.REMOTE_TAG_ORDER.contains("c DESC"))
        XCTAssertFalse(
            ActorTagSql.REMOTE_TAG_ORDER.contains("tag_name"),
            "tag_name 有历史变体，不能作分组/排序键")
    }

    /// localTagOrderHasTagIdTiebreaker：离线聚合 tiebreaker 按 mt.tag_id
    func testLocalTagOrderHasTagIdTiebreaker() {
        XCTAssertTrue(ActorTagSql.LOCAL_TAG_ORDER.contains("mt.tag_id ASC"))
    }

    /// localTaggedCountMatchesActorMoviesShape：本地计数 JOIN idx 两张关系表
    func testLocalTaggedCountMatchesActorMoviesShape() {
        let sql = ActorTagSql.LOCAL_COUNT_TAGGED
        XCTAssertTrue(sql.contains("JOIN idx_movie_actors"))
        XCTAssertTrue(sql.contains("JOIN idx_movie_tags"))
        XCTAssertTrue(sql.contains("mt.tag_id = ?"))
    }
}
