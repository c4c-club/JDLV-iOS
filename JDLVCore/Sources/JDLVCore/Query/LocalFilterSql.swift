import Foundation

/// 离线筛选 DSL 的能力声明（当前 idx v3 能力）。
/// cnsub/canPlay 默认 false —— 索引库无此能力，fail-closed。
public struct LocalCaps: Equatable {
    public var year: Bool
    public var month: Bool
    public var letter: Bool
    public var maker: Bool
    public var series: Bool
    public var director: Bool
    public var publisher: Bool
    public var tags: Bool
    public var magnet: Bool
    public var single: Bool
    public var cnsub: Bool
    public var canPlay: Bool

    public init(
        year: Bool = true, month: Bool = true, letter: Bool = true, maker: Bool = true,
        series: Bool = true, director: Bool = true, publisher: Bool = true, tags: Bool = true,
        magnet: Bool = true, single: Bool = true, cnsub: Bool = false, canPlay: Bool = false
    ) {
        self.year = year; self.month = month; self.letter = letter; self.maker = maker
        self.series = series; self.director = director; self.publisher = publisher
        self.tags = tags; self.magnet = magnet; self.single = single
        self.cnsub = cnsub; self.canPlay = canPlay
    }
}

public struct LocalQuery: Equatable {
    public var where: String
    public var params: [String]
    public var unsupported: [String]
    public var empty: Bool
    public var reason: String

    public init(where: String, params: [String], unsupported: [String] = [],
                empty: Bool = false, reason: String = "") {
        self.where = where
        self.params = params
        self.unsupported = unsupported
        self.empty = empty
        self.reason = reason
    }
}

/// 离线筛选 DSL。
/// 任何"设置了但当前库表达不了"的条件一律 fail-closed：`empty=true` + `WHERE 1=0`，
/// 绝不静默丢弃条件后返回全量。
public enum LocalFilterSql {

    /// LIKE 特殊字符转义（% _ \），与 SQL 的 ESCAPE '\' 配套（顺序不可换）
    static func escLike(_ w: String) -> String {
        w.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    public static func build(
        _ f: Filters,
        tagIds: [String],
        singleTagIds: [String],
        caps: LocalCaps,
        monthRange: (String, String) -> (String, String)?
    ) -> LocalQuery {
        var clauses: [String] = []
        var params: [String] = []
        var unsupported: [String] = []
        var reasons: [String] = []

        func deny(_ label: String) {
            unsupported.append(label)
            reasons.append("\(label)：离线不支持该条件，请联网或清除该条件")
        }

        if !f.year.trimmingCharacters(in: .whitespaces).isEmpty {
            if caps.year {
                clauses.append("year = ?")
                params.append(f.year.trimmingCharacters(in: .whitespaces))
            } else {
                deny("年份")
            }
        }

        if !f.month.trimmingCharacters(in: .whitespaces).isEmpty {
            if !caps.month {
                deny("月份")
            } else if !f.year.trimmingCharacters(in: .whitespaces).isEmpty {
                if let range = monthRange(
                    f.year.trimmingCharacters(in: .whitespaces),
                    f.month.trimmingCharacters(in: .whitespaces)) {
                    clauses.append("release_date >= ? AND release_date < ?")
                    params.append(range.0)
                    params.append(range.1)
                } else {
                    reasons.append("年份/月份非法，无法生成日期区间")
                }
            } else {
                let m = Int(f.month.trimmingCharacters(in: .whitespaces))
                if m == nil || !(1...12 ~= m!) {
                    reasons.append("月份非法")
                } else {
                    clauses.append("substr(release_date, 6, 2) = ?")
                    params.append(String(format: "%02d", m!))
                }
            }
        }

        if !f.letter.trimmingCharacters(in: .whitespaces).isEmpty {
            if caps.letter {
                let p = f.letter.trimmingCharacters(in: .whitespaces)
                    .lowercased()
                    .filter { !$0.isWhitespace }
                if !p.isEmpty {
                    clauses.append("number LIKE ? ESCAPE '\\'")
                    params.append(escLike(p) + "%")
                }
            } else {
                deny("字头")
            }
        }

        if !f.maker.trimmingCharacters(in: .whitespaces).isEmpty {
            if caps.maker {
                clauses.append("maker_id = ?")
                params.append(f.maker.trimmingCharacters(in: .whitespaces))
            } else { deny("片商") }
        }
        if !f.seriesId.trimmingCharacters(in: .whitespaces).isEmpty {
            if caps.series {
                clauses.append("series_id = ?")
                params.append(f.seriesId.trimmingCharacters(in: .whitespaces))
            } else { deny("系列") }
        }
        if !f.directorId.trimmingCharacters(in: .whitespaces).isEmpty {
            if caps.director {
                clauses.append("director_id = ?")
                params.append(f.directorId.trimmingCharacters(in: .whitespaces))
            } else { deny("导演") }
        }
        if !f.publisherId.trimmingCharacters(in: .whitespaces).isEmpty {
            if caps.publisher {
                clauses.append("publisher_id = ?")
                params.append(f.publisherId.trimmingCharacters(in: .whitespaces))
            } else { deny("发行商") }
        }

        let requestedTags = f.tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // distinct（保序）
        var seen = Set<String>()
        let distinctTags = requestedTags.filter { seen.insert($0).inserted }

        if !distinctTags.isEmpty {
            if !caps.tags {
                deny("标签")
            } else if tagIds.isEmpty {
                reasons.append("标签名无法映射 (需先联网加载标签索引)")
            } else {
                for id in tagIds {
                    clauses.append("id IN (SELECT movie_id FROM idx_movie_tags WHERE tag_id = ?)")
                    params.append(id)
                }
            }
        }

        if f.magnet {
            if caps.magnet {
                clauses.append("magnets > 0")
            } else { deny("磁力") }
        }

        if f.single {
            if !caps.single {
                deny("单体")
            } else if singleTagIds.isEmpty {
                reasons.append("标签索引未就绪，无法执行单体筛选")
            } else {
                let ph = singleTagIds.map { _ in "?" }.joined(separator: ",")
                clauses.append(
                    "id IN (SELECT movie_id FROM idx_movie_tags WHERE tag_id IN (\(ph)))")
                params.append(contentsOf: singleTagIds)
            }
        }

        if f.cnsub {
            if caps.cnsub {
                clauses.append("has_cnsub = 1")
            } else { deny("无码") }
        }
        if f.canPlay {
            if caps.canPlay {
                clauses.append("can_play = 1")
            } else { deny("可播放") }
        }

        if !reasons.isEmpty {
            return LocalQuery(
                where: " WHERE 1=0",
                params: [],
                unsupported: unsupported,
                empty: true,
                reason: reasons.joined(separator: "；"))
        }

        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return LocalQuery(where: whereClause, params: params, unsupported: unsupported,
                          empty: false, reason: "")
    }
}
