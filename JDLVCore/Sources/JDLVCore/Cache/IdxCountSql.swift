import Foundation

/// 本地"影片数"类 COUNT 与列表同口径。
/// 列清单/表名集中在这里，IdxDb 只执行；计数必须 JOIN idx_movies（关系表孤儿不计入）。
public enum IdxCountSql {
    public static let ACTOR_NO_TAG =
        "SELECT COUNT(*) FROM idx_movies m JOIN idx_movie_actors ma ON ma.movie_id = m.id " +
        "WHERE ma.actor_id = ?"

    public static let ACTOR_TAGGED =
        "SELECT COUNT(*) FROM idx_movies m " +
        "JOIN idx_movie_actors ma ON ma.movie_id = m.id " +
        "JOIN idx_movie_tags mt ON mt.movie_id = m.id AND mt.tag_id = ? " +
        "WHERE ma.actor_id = ?"

    public static let TAG_COUNT =
        "SELECT COUNT(*) FROM idx_movies m JOIN idx_movie_tags mt ON mt.movie_id = m.id " +
        "WHERE mt.tag_id = ?"

    public static func actorMovieCount(hasTag: Bool) -> String {
        hasTag ? ACTOR_TAGGED : ACTOR_NO_TAG
    }
}
