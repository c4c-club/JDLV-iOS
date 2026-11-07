import Foundation
import JDLVCore

//
//  DemoDataSource.swift —— 演示数据源（★ 仅 DEBUG；Release 整文件为空实现）。
//
//  - 启用条件：launch arg `-JDLV_DEMO 1`（UI 测试/演示用）。
//  - DemoStore 单例：进程内 SQLite 临时库（JDLVCore Store/SQLite.swift），启动时合成：
//    ≥120 影片 / ≥60 女优 / ≥80 帖子 / ≥20 资讯 / ≥20 热评 / TOP250 25 条
//    （标题「演示影片 001」式，3 位零填充；确定性 LCG 种子，数据可复现）。
//  - 列名与真实库一致（P9 页面层零改动切换）：movies 的
//    id/number/number_letter/title/release_date/year/score/reviews_count/
//    want_watch_count/watched_count/magnets_count/cover_url/duration/has_cnsub/
//    summary/maker/series/director/publisher/tags；actors 的
//    name/avatar_url/videos_count/gender/avg_score_all…；threads 的
//    tid/title/post_date/board_name/cat_name/type…；hot_reviews 的
//    rid/rank/likes_count/content… 等。
//  - 图片位全部走 TestImages：cover_url/avatar_url 只放合成 URL 字符串，
//    PosterImage 在 demo 模式（DemoDataSource.enabled()）直接渲染 TestImages
//    纯色块，不发网络请求（见 UI/Common/PosterImage.swift）。
//  - 查询 API 签名固定（P9 页面 VM 直接调用），全部返回 JDLVCore Row。
//

#if DEBUG

/// 启用开关（launch argument）。
enum DemoDataSource {
    /// `-JDLV_DEMO 1` 启用（其余值/缺失 = 关闭）—— A8/R8 起与 LaunchMode 共用唯一判定。
    static func enabled() -> Bool {
        LaunchMode.current == .demo
    }
}

// MARK: - DemoStore（进程内 SQLite 临时库单例）

final class DemoStore {
    static let shared: DemoStore = DemoStore()

    /// 合成数据规模（满足 P8 下限：120/60/80/20/20/25）
    static let movieCount = 132
    static let actorCount = 72
    static let threadCount = 96
    static let articleCount = 24
    /// 6 个 period × 2 批次 × 12 条 = 144
    static let hotReviewCount = 144
    static let top250Count = 25

    private let db: SQLite
    private let lock = NSRecursiveLock()

    private init() {
        // 进程内临时库：随进程生命周期存在，退出由系统清理临时目录
        let path = NSTemporaryDirectory() + "jdlv_demo_\(UUID().uuidString).sqlite3"
        let opened = try! SQLite(path: path, wal: false)
        db = opened
        try! Self.build(db: opened)
    }

    // MARK: 查询 API（签名固定，P9 直接用）

    /// 首页三段：recent（最近更新）/ hot（最多想看）/ top（TOP250）
    func homeSections(per: Int) -> [String: [Row]] {
        lock.lock(); defer { lock.unlock() }
        let p = max(1, min(per, 100))
        return [
            "recent": rows("SELECT * FROM movies ORDER BY release_date DESC, id DESC LIMIT \(p)"),
            "hot": rows("SELECT * FROM movies ORDER BY want_watch_count DESC, id DESC LIMIT \(p)"),
            "top": rows("SELECT m.*, r.`rank` AS rank FROM rankings_top250 r "
                        + "JOIN movies m ON m.id = r.movie_id ORDER BY r.`rank` LIMIT \(p)"),
        ]
    }

    /// 浏览（12 字段筛选 + 排序方向 + 分页）。
    /// 返回对齐 Android Q.browse：items/total/approx/anchor/derived。
    func browse(f: Filters, page: Int, per: Int, sort: String, asc: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var wh: [String] = []
        var params: [SQLValue?] = []
        if !f.year.isEmpty {
            wh.append("year = ?"); params.append(.string(f.year))
        }
        if !f.month.isEmpty {
            wh.append("substr(release_date, 6, 2) = ?"); params.append(.string(f.month))
        }
        if !f.letter.isEmpty {
            wh.append("number LIKE ?"); params.append(.string("\(f.letter.lowercased())%"))
        }
        if !f.maker.isEmpty {
            wh.append("maker_name = ?"); params.append(.string(f.maker))
        }
        if !f.seriesId.isEmpty {
            wh.append("series_name = ?"); params.append(.string(f.seriesId))
        }
        if !f.directorId.isEmpty {
            wh.append("director_name = ?"); params.append(.string(f.directorId))
        }
        if !f.publisherId.isEmpty {
            wh.append("publisher_name = ?"); params.append(.string(f.publisherId))
        }
        for tag in f.tags.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !tag.isEmpty {
            wh.append("(',' || tags || ',') LIKE ?"); params.append(.string("%,\(tag),%"))
        }
        if f.magnet { wh.append("magnets_count > 0") }
        if f.cnsub { wh.append("has_cnsub = 1") }
        let whereSql = wh.isEmpty ? "" : "WHERE " + wh.joined(separator: " AND ")
        let orderCol = ["release_date", "id", "score", "want_watch_count"].contains(sort)
            ? sort : "release_date"
        let dir = asc ? "ASC" : "DESC"
        let p = max(1, min(per, 200))
        let off = max(0, max(1, page) - 1) * p
        let items = rows("SELECT * FROM movies \(whereSql) ORDER BY \(orderCol) \(dir), id DESC "
                         + "LIMIT \(p) OFFSET \(off)", params)
        let totalRow = rows("SELECT COUNT(*) AS c FROM movies \(whereSql)", params)
        let total = totalRow.first?.i("c") ?? 0
        return ["items": items, "total": total, "approx": false, "anchor": "", "derived": ""]
    }

    /// 影片详情行（无此 id → nil）
    func movie(mid: String) -> Row? {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT * FROM movies WHERE id = ?", [.string(mid)]).first
    }

    /// 女优列表（per 默认 30；gender: f/m/all；sort: videos/popularity/name/debut/avg_solo/avg_all）
    func actors(page: Int, per: Int, sort: String, gender: String, q: String) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var wh: [String] = []
        var params: [SQLValue?] = []
        switch gender {
        case "f": wh.append("gender = 0")
        case "m": wh.append("gender = 1")
        default: break
        }
        let term = q.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            wh.append("name LIKE ?"); params.append(.string("%\(term)%"))
        }
        let whereSql = wh.isEmpty ? "" : "WHERE " + wh.joined(separator: " AND ")
        let orderCol: String
        switch sort {
        case "popularity": orderCol = "popularity"
        case "name": orderCol = "name"
        case "debut": orderCol = "debut"
        case "avg_solo": orderCol = "avg_score_solo"
        case "avg_all": orderCol = "avg_score_all"
        default: orderCol = "videos_count"
        }
        let p = max(1, min(per, 200))
        let off = max(0, max(1, page) - 1) * p
        return rows("SELECT * FROM actors \(whereSql) ORDER BY \(orderCol) DESC, id ASC "
                    + "LIMIT \(p) OFFSET \(off)", params)
    }

    /// 女优详情行
    func actor(aid: String) -> Row? {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT * FROM actors WHERE id = ?", [.string(aid)]).first
    }

    /// 女优出演影片（每页 24）
    func actorMovies(aid: String, page: Int) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let p = 24
        let off = max(0, max(1, page) - 1) * p
        return rows("SELECT m.* FROM movie_actors ma JOIN movies m ON m.id = ma.movie_id "
                    + "WHERE ma.actor_id = ? ORDER BY m.release_date DESC, m.id DESC "
                    + "LIMIT \(p) OFFSET \(off)", [.string(aid)])
    }

    /// 98t 帖子列表（main=主版 board / cat=副版 board_name / type=分类；q：空格分词=且、
    /// 3~12 位纯数字=按帖子 ID 直达）
    func shtList(main: String, cat: String, type: String, q: String, page: Int, per: Int) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var wh: [String] = []
        var params: [SQLValue?] = []
        if !main.isEmpty { wh.append("board = ?"); params.append(.string(main)) }
        if !cat.isEmpty { wh.append("board_name = ?"); params.append(.string(cat)) }
        if !type.isEmpty { wh.append("type = ?"); params.append(.string(type)) }
        let term = q.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            if term.count >= 3, term.count <= 12, term.allSatisfy(\.isNumber) {
                wh.append("tid = ?"); params.append(.string(term))
            } else {
                for w in term.split(whereSeparator: { $0.isWhitespace }).prefix(8) {
                    wh.append("title LIKE ?"); params.append(.string("%\(w)%"))
                }
            }
        }
        let whereSql = wh.isEmpty ? "" : "WHERE " + wh.joined(separator: " AND ")
        let p = max(1, min(per, 200))
        let off = max(0, max(1, page) - 1) * p
        return rows("SELECT * FROM threads \(whereSql) ORDER BY post_date DESC, tid DESC "
                    + "LIMIT \(p) OFFSET \(off)", params)
    }

    /// 帖子详情行（无此 tid → nil）
    func shtThread(tid: String) -> Row? {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT * FROM threads WHERE tid = ?", [.string(tid)]).first
    }

    /// 资讯列表（每页 24，ORDER BY released_at DESC；categoryId 空 = 全部）
    func articles(page: Int, categoryId: String, q: String) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var wh: [String] = []
        var params: [SQLValue?] = []
        if !categoryId.isEmpty {
            wh.append("category_id = ?"); params.append(.string(categoryId))
        }
        let term = q.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            wh.append("(title LIKE ? OR content_text LIKE ?)")
            params.append(.string("%\(term)%")); params.append(.string("%\(term)%"))
        }
        let whereSql = wh.isEmpty ? "" : "WHERE " + wh.joined(separator: " AND ")
        let p = 24
        let off = max(0, max(1, page) - 1) * p
        return rows("SELECT * FROM articles \(whereSql) ORDER BY released_at DESC, id DESC "
                    + "LIMIT \(p) OFFSET \(off)", params)
    }

    /// 资讯详情行
    func article(aid: String) -> Row? {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT * FROM articles WHERE id = ?", [.string(aid)]).first
    }

    /// 热评（period=all/weekly/monthly/quarterly/yearly/latest；key 空 = 该 period 最新批次；
    /// 每页 24，ORDER BY rank）
    func hotReviews(period: String, key: String, page: Int) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var params: [SQLValue?] = [.string(period)]
        var keySql = ""
        if key.isEmpty {
            keySql = "AND period_key = (SELECT MAX(period_key) FROM hot_reviews WHERE period = ?)"
            params.append(.string(period))
        } else {
            keySql = "AND period_key = ?"
            params.append(.string(key))
        }
        let p = 24
        let off = max(0, max(1, page) - 1) * p
        return rows("SELECT * FROM hot_reviews WHERE period = ? \(keySql) "
                    + "ORDER BY `rank` ASC LIMIT \(p) OFFSET \(off)", params)
    }

    /// TOP250 年份分布（GROUP BY m.year；列 year/n）
    func top250Years() -> [Row] {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT m.year AS year, COUNT(*) AS n FROM rankings_top250 r "
                    + "JOIN movies m ON m.id = r.movie_id GROUP BY m.year ORDER BY m.year DESC")
    }

    /// TOP250 榜单（year 空 = 全部；每页 40，ORDER BY rank）
    func top250(year: String, page: Int) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var params: [SQLValue?] = []
        var whereSql = ""
        if !year.isEmpty {
            whereSql = "WHERE m.year = ?"
            params.append(.string(year))
        }
        let p = 40
        let off = max(0, max(1, page) - 1) * p
        return rows("SELECT m.*, r.`rank` AS rank FROM rankings_top250 r "
                    + "JOIN movies m ON m.id = r.movie_id \(whereSql) "
                    + "ORDER BY r.`rank` ASC LIMIT \(p) OFFSET \(off)", params)
    }

    /// 收藏列表（kind = movie/sht/actor；ts 倒序）
    func favList(kind: String) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT kind, id, title, ts FROM favorites WHERE kind = ? ORDER BY ts DESC",
                    [.string(kind)])
    }

    // MARK: 内部查询助手

    private func rows(_ sql: String, _ params: [SQLValue?] = []) -> [Row] {
        do {
            return try db.query(sql, params)
        } catch {
            assertionFailure("DemoStore SQL failed: \(error) sql=\(sql)")
            return []
        }
    }

    // MARK: 建库与合成数据

    private static func build(db: SQLite) throws {
        // SQLite.exec 一次只执行一条语句（prepare_v2 忽略尾部语句）→ 逐条建表
        let ddl: [String] = [
            """
            CREATE TABLE IF NOT EXISTS movies (
                id TEXT PRIMARY KEY, number TEXT, number_letter TEXT, title TEXT,
                release_date TEXT, year TEXT, score REAL, reviews_count INTEGER,
                want_watch_count INTEGER, watched_count INTEGER, magnets_count INTEGER,
                cover_url TEXT, duration TEXT, has_cnsub INTEGER, summary TEXT,
                maker_id TEXT, maker_name TEXT, series_id TEXT, series_name TEXT,
                director_id TEXT, director_name TEXT, publisher_id TEXT, publisher_name TEXT,
                tags TEXT, derived TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS actors (
                id TEXT PRIMARY KEY, name TEXT, name_zht TEXT, other_name TEXT,
                avatar_url TEXT, videos_count INTEGER, gender INTEGER,
                avg_score_all REAL, avg_score_solo REAL, popularity INTEGER,
                birthday TEXT, height TEXT, debut TEXT, twitter TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS movie_actors (
                movie_id TEXT, actor_id TEXT, actor_name TEXT, gender INTEGER
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS threads (
                tid TEXT PRIMARY KEY, title TEXT, board TEXT, board_name TEXT,
                cat_name TEXT, type TEXT, post_date TEXT, magnet_count INTEGER,
                words INTEGER, cover_url TEXT, last_checked TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS articles (
                id TEXT PRIMARY KEY, title TEXT, category_id TEXT, category_name TEXT,
                author TEXT, origin_name TEXT, released_at TEXT, word_count INTEGER,
                cover_url TEXT, content_text TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS hot_reviews (
                rid TEXT PRIMARY KEY, period TEXT, period_key TEXT, `rank` INTEGER,
                movie_id TEXT, number TEXT, movie_title TEXT, movie_score REAL,
                movie_thumb_url TEXT, user_name TEXT, score TEXT, likes_count TEXT,
                content TEXT, created_at TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS rankings_top250 (
                movie_id TEXT, `rank` INTEGER, year INTEGER
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS favorites (
                kind TEXT, id TEXT, title TEXT, ts INTEGER
            )
            """,
        ]
        for stmt in ddl {
            try db.exec(stmt)
        }

        var rng = LCG(seed: 0x4A44_4C56)   // "JDLV"
        try db.transaction {
            try insertMovies(db: db, rng: &rng)
            try insertActors(db: db, rng: &rng)
            try insertMovieActors(db: db, rng: &rng)
            try insertThreads(db: db, rng: &rng)
            try insertArticles(db: db, rng: &rng)
            try insertHotReviews(db: db, rng: &rng)
            try insertTop250(db: db)
            try insertFavorites(db: db, rng: &rng)
        }
    }

    private static func insertMovies(db: SQLite, rng: inout LCG) throws {
        let prefixes = ["ABC", "IPX", "SSIS", "MIDE", "ABP", "JUL", "MIMK", "FC2", "SDDE", "MVSD"]
        let makers = ["SOD create", "Moodyz", "IdeaPocket", "Prestige", "Wanz Factory", "-opium-"]
        let series = ["演示系列 A", "演示系列 B", "演示系列 C", ""]
        let directors = ["演示导演 1", "演示导演 2", ""]
        let publishers = ["演示发行商 1", "演示发行商 2", "演示发行商 3"]
        let tagPool = ["企划", "单体作品", "中文字幕", "薄格", "巨乳", "制服", "解说", "职业"]
        let sql = "INSERT INTO movies (id, number, number_letter, title, release_date, year, score, "
            + "reviews_count, want_watch_count, watched_count, magnets_count, cover_url, duration, "
            + "has_cnsub, summary, maker_id, maker_name, series_id, series_name, director_id, "
            + "director_name, publisher_id, publisher_name, tags, derived) "
            + "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        for i in 0..<movieCount {
            let id = String(100_000 + i)
            let prefix = prefixes[rng.next(prefixes.count)]
            let n = String(format: "%03d", i + 1)
            let number = "\(prefix)-\(n)"
            let title = "演示影片 \(n)"
            let year = 2015 + rng.next(12)
            let month = 1 + rng.next(12)
            let day = 1 + rng.next(28)
            let releaseDate = String(format: "%04d-%02d-%02d", year, month, day)
            let score: Double = rng.next(20) == 0
                ? 0
                : (Double(30 + rng.next(20)) / 10.0)
            let reviews = rng.next(800)
            let want = rng.next(5000)
            let watched = rng.next(9000)
            let magnets = rng.next(8) == 0 ? 0 : rng.next(20)
            let cover = rng.next(10) == 0 ? "" : "https://demo.jdlv.local/cover/\(id).jpg"
            let duration = "\(60 + rng.next(150))"
            let cnsub = rng.next(3) == 0 ? 1 : 0
            let summary = "演示影片 \(n) 的剧情简介（合成数据）。"
            let maker = makers[rng.next(makers.count)]
            let series = series[rng.next(series.count)]
            let director = directors[rng.next(directors.count)]
            let publisher = publishers[rng.next(publishers.count)]
            var tagSet: [String] = []
            for t in tagPool where rng.next(4) == 0 { tagSet.append(t) }
            if tagSet.isEmpty { tagSet.append(tagPool[0]) }
            let tags = tagSet.joined(separator: ",")
            try db.run(sql, [
                .string(id), .string(number), .string(String(prefix.prefix(1)).lowercased()),
                .string(title), .string(releaseDate), .string(String(year)),
                .double(score), .int(Int64(reviews)), .int(Int64(want)), .int(Int64(watched)),
                .int(Int64(magnets)), .string(cover), .string(duration), .int(Int64(cnsub)),
                .string(summary), .string(maker), .string(maker),
                .string(series.isEmpty ? "s0" : series), .string(series),
                .string(director.isEmpty ? "d0" : director), .string(director),
                .string(publisher), .string(publisher),
                .string(tags), .string(""),
            ])
        }
    }

    private static func insertActors(db: SQLite, rng: inout LCG) throws {
        let sql = "INSERT INTO actors (id, name, name_zht, other_name, avatar_url, videos_count, "
            + "gender, avg_score_all, avg_score_solo, popularity, birthday, height, debut, twitter) "
            + "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        for i in 0..<actorCount {
            let id = String(200_000 + i)
            let n = String(format: "%03d", i + 1)
            let gender = (i % 9 == 8) ? 1 : 0     // 少量男优（B5：♀粉 ♂蓝）
            let name = gender == 1 ? "演示男优 \(n)" : "演示女优 \(n)"
            let avatar = rng.next(6) == 0 ? "" : "https://demo.jdlv.local/avatar/\(id).jpg"
            let videos = Int64(3 + rng.next(180))
            let avgAll: Double = rng.next(6) == 0 ? 0 : (Double(30 + rng.next(20)) / 10.0)
            let avgSolo: Double = rng.next(6) == 0 ? 0 : (Double(30 + rng.next(20)) / 10.0)
            let popularity = Int64(rng.next(10000))
            let birthday = String(format: "199%d-%02d-%02d", rng.next(10), 1 + rng.next(12), 1 + rng.next(28))
            let height = Int64(150 + rng.next(40))
            let debut = String(format: "20%02d-%02d", rng.next(20), 1 + rng.next(12))
            try db.run(sql, [
                .string(id), .string(name), .string(""), .string(""),
                .string(avatar), .int(videos), .int(Int64(gender)),
                .double(avgAll), .double(avgSolo), .int(popularity),
                .string(birthday), .int(height), .string(debut),
                .string("@demo_\(n)"),
            ])
        }
    }

    private static func insertMovieActors(db: SQLite, rng: inout LCG) throws {
        let sql = "INSERT INTO movie_actors (movie_id, actor_id, actor_name, gender) VALUES (?,?,?,?)"
        for i in 0..<movieCount {
            let movieId = String(100_000 + i)
            let count = 1 + rng.next(3)
            var used: Set<Int> = []
            for _ in 0..<count {
                let a = rng.next(actorCount)
                guard used.insert(a).inserted else { continue }
                let actorId = String(200_000 + a)
                let gender = (a % 9 == 8) ? 1 : 0
                let name = gender == 1 ? "演示男优 \(String(format: "%03d", a + 1))"
                                       : "演示女优 \(String(format: "%03d", a + 1))"
                try db.run(sql, [.string(movieId), .string(actorId), .string(name), .int(Int64(gender))])
            }
        }
    }

    private static func insertThreads(db: SQLite, rng: inout LCG) throws {
        let boards: [(main: String, subs: [String], types: [String])] = [
            ("有码中文字幕", ["有码原创", "有码首发"], ["高清", "原盘", "字幕"]),
            ("无码中文字幕", ["无码原创", "无码首发"], ["高清", "合集"]),
            ("自拍图片区", ["自贴图", "转贴图"], ["图集"]),
            ("小说文学区", ["原创小说", "转载小说"], ["文集"]),
        ]
        let sql = "INSERT INTO threads (tid, title, board, board_name, cat_name, type, post_date, "
            + "magnet_count, words, cover_url, last_checked) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
        for i in 0..<threadCount {
            let tid = String(300_000 + i)
            let n = String(format: "%03d", i + 1)
            let b = boards[rng.next(boards.count)]
            let sub = b.subs[rng.next(b.subs.count)]
            let type = b.types[rng.next(b.types.count)]
            let cat = b.main
            let year = 2023 + rng.next(4)
            let postDate = String(format: "%04d-%02d-%02d", year, 1 + rng.next(12), 1 + rng.next(28))
            let isImage = cat == "自拍图片区"
            let isLiterature = cat == "小说文学区"
            let magnetCount = isLiterature ? 0 : rng.next(12)
            let words = isLiterature ? 3000 + rng.next(17000) : 0
            let cover: String
            if isImage || rng.next(2) == 0 {
                cover = "https://demo.jdlv.local/thread/\(tid).jpg"
            } else {
                cover = ""
            }
            try db.run(sql, [
                .string(tid), .string("演示帖子 \(n)"), .string(b.main), .string(sub),
                .string(cat), .string(type), .string(postDate), .int(Int64(magnetCount)),
                .int(Int64(words)), .string(cover),
                .string(String(format: "%04d-%02d-%02d %02d:%02d", year, 1 + rng.next(12),
                               1 + rng.next(28), rng.next(24), rng.next(60))),
            ])
        }
    }

    private static func insertArticles(db: SQLite, rng: inout LCG) throws {
        let cats: [(id: String, name: String)] = [
            ("1", "业界"), ("2", "评论"), ("3", "访谈"), ("4", "写真"),
        ]
        let sql = "INSERT INTO articles (id, title, category_id, category_name, author, origin_name, "
            + "released_at, word_count, cover_url, content_text) VALUES (?,?,?,?,?,?,?,?,?,?)"
        for i in 0..<articleCount {
            let id = String(400_000 + i)
            let n = String(format: "%03d", i + 1)
            let cat = cats[rng.next(cats.count)]
            let releasedAt = String(format: "2026-%02d-%02d 10:%02d:00", 1 + rng.next(10),
                                    1 + rng.next(28), rng.next(60))
            let words = 500 + rng.next(8000)
            let cover = rng.next(3) == 0 ? "" : "https://demo.jdlv.local/article/\(id).jpg"
            try db.run(sql, [
                .string(id), .string("演示资讯 \(n)"), .string(cat.id), .string(cat.name),
                .string("演示作者"), .string("演示来源"), .string(releasedAt),
                .int(Int64(words)), .string(cover),
                .string("演示资讯 \(n) 正文内容（合成数据）。"),
            ])
        }
    }

    private static func insertHotReviews(db: SQLite, rng: inout LCG) throws {
        let periods: [(name: String, keyFmt: (Int) -> String)] = [
            ("all", { _ in "latest" }),
            ("weekly", { w in "2026-W\(String(format: "%02d", w))" }),
            ("monthly", { m in String(format: "2026-%02d", m) }),
            ("quarterly", { q in "2026-Q\((q % 4) + 1)" }),
            ("yearly", { _ in "2026" }),
            ("latest", { _ in "latest" }),
        ]
        let sql = "INSERT INTO hot_reviews (rid, period, period_key, `rank`, movie_id, number, "
            + "movie_title, movie_score, movie_thumb_url, user_name, score, likes_count, "
            + "content, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        var rid = 0
        for p in periods {
            for k in 0..<2 {
                for r in 1...12 {
                    rid += 1
                    let movieIdx = rng.next(movieCount)
                    let movieId = String(100_000 + movieIdx)
                    let n = String(format: "%03d", movieIdx + 1)
                    let likes = rng.next(500)
                    try db.run(sql, [
                        .string(String(500_000 + rid)), .string(p.name),
                        .string(p.keyFmt(k + 1)), .int(Int64(r)), .string(movieId),
                        .string("DEMO-\(n)"), .string("演示影片 \(n)"),
                        .double(Double(30 + rng.next(20)) / 10.0),
                        .string("https://demo.jdlv.local/cover/\(movieId).jpg"),
                        .string("网友 \(rng.next(999))"), .string(String(format: "%.1f", Double(30 + rng.next(20)) / 10.0)),
                        .string(String(likes)), .string("演示热评内容 \(rid)：这条评论是合成数据。"),
                        .string("2026-10-\(String(format: "%02d", 1 + rng.next(28))) 12:00:00"),
                    ])
                }
            }
        }
    }

    private static func insertTop250(db: SQLite) throws {
        let sql = "INSERT INTO rankings_top250 (movie_id, `rank`, year) VALUES (?,?,?)"
        for r in 1...top250Count {
            let movieId = String(100_000 + r - 1)
            try db.run(sql, [.string(movieId), .int(Int64(r)), .int(2026)])
        }
    }

    private static func insertFavorites(db: SQLite, rng: inout LCG) throws {
        let sql = "INSERT INTO favorites (kind, id, title, ts) VALUES (?,?,?,?)"
        let now = storeNowMs()
        for i in 0..<3 {
            let n = String(format: "%03d", i + 1)
            try db.run(sql, [.string("movie"), .string(String(100_000 + i)),
                             .string("演示影片 \(n)"), .int(now - Int64(i) * 86_400_000)])
        }
        for i in 0..<2 {
            let n = String(format: "%03d", i + 1)
            try db.run(sql, [.string("sht"), .string(String(300_000 + i)),
                             .string("演示帖子 \(n)"), .int(now - Int64(i) * 3_600_000)])
        }
        for i in 0..<2 {
            let n = String(format: "%03d", i + 1)
            try db.run(sql, [.string("actor"), .string(String(200_000 + i)),
                             .string("演示女优 \(n)"), .int(now - Int64(i) * 720_000)])
        }
        _ = rng   // 占位：收藏数据不需要随机
    }
}

// MARK: - 确定性随机（LCG；跨次启动数据一致）

private struct LCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// [0, n) 均匀整数
    mutating func next(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
}

#else

/// Release：演示数据源恒不可用（占位，调用点均在 #if DEBUG 内）。
enum DemoDataSource {
    static func enabled() -> Bool { false }
}

#endif
