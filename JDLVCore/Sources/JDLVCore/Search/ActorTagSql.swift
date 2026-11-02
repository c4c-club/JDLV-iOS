import Foundation

/// 女优×标签筛选的 SQL 口径（count 与 items 完全同口径）。
public enum ActorTagSql {
    public static let COUNT_PLAIN =
        "SELECT COUNT(*) FROM movie_actors WHERE actor_id = ?"

    public static let COUNT_TAGGED =
        "SELECT COUNT(*) FROM movie_actors ma " +
        "JOIN movies m ON m.id = ma.movie_id " +
        "WHERE ma.actor_id = ? AND m.id IN " +
        "(SELECT movie_id FROM movie_tags WHERE tag_id = ?)"

    public static let LOCAL_COUNT_PLAIN =
        "SELECT COUNT(*) FROM idx_movie_actors WHERE actor_id = ?"

    public static let LOCAL_COUNT_TAGGED =
        "SELECT COUNT(*) FROM idx_movies m " +
        "JOIN idx_movie_actors ma ON ma.movie_id = m.id " +
        "JOIN idx_movie_tags mt ON mt.movie_id = m.id AND mt.tag_id = ? " +
        "WHERE ma.actor_id = ?"

    /// 远程标签聚合固定 tiebreaker：按 tag_id 唯一分组后升序（tag_name 有历史变体，不能作分组键）。
    public static let REMOTE_TAG_ORDER = "ORDER BY c DESC, tag_id ASC"

    /// 离线标签聚合固定 tiebreaker：计数相同按 tag_id 升序。
    public static let LOCAL_TAG_ORDER = "ORDER BY c DESC, mt.tag_id ASC"

    public static func remoteCount(tagged: Bool) -> String {
        tagged ? COUNT_TAGGED : COUNT_PLAIN
    }

    public static func remoteParams(_ mainId: String, _ tagId: String) -> [String] {
        tagId.isEmpty ? [mainId] : [mainId, tagId]
    }
}
