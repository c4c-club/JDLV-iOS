import XCTest
import MySQLNIO
@testable import JDLVCore

// Q 查询层集成测试（真实 MySQL 8 fixture；与 MySQLIntegrationTests 同一套基建模式，
// 独立 fixture 库 jdlv_it_q / jdlv_it_q_alt，不改动现有任何文件）。
// 由 core-mysql job 运行（env 提供连接参数，缺省 127.0.0.1:3306 root/root）。
//
// ★ 断言总数：370（85 个测试方法；grep -o "XCTAssert[A-Za-z]*" 统计，不含本行）。
//
// 覆盖的 Q 公开函数（34 个）：
//   movieCols / home / top250 / top250Years / search / searchCount /
//   browse / browseCount / movie / movieByNumber / movieCovers /
//   actors / actorsCount / actor / actorTags / actorTagCount /
//   shtCategories / shtBrowse / shtBrowseCount / shtThread / shtExport / shtSemantic /
//   articles / article / articleMovies / articleCategories / movieArticles /
//   hotReviewKeys / hotReviews / taxonomy / filters / tagIdByName / tagNameOf
//
// 口径要点（docs/_extract/02_q_db.md B 节）：
//   - home 三段排序（release_date / want_watch_count / `rank` 反引号）+ per 参数化
//   - top250 `rank` 反引号排序 + 年份筛选（movies.year）+ COUNT 同步 + OFFSET 无钳制
//   - search 7 范围：number 前缀 / letter / fts(英文 token) / 派生 LIKE 兜底(中文 0 命中) /
//     actor(前缀→IN) / tag(tag_id 反查) / all 三路 UNION / exact.number；跳页过深空页
//   - browse 12 筛选组合（年 / 年+月半开区间 / 仅月派生窗口 20000 / 字头前缀 LIKE /
//     片商 / 标签 AND / magnet / 单体 tag_id IN / 系列 / 导演 / 发行商 / 组合）
//     + 排序 4 键×正倒序 + keyset 续页 + OFFSET 5000 钳制（空页）
//   - browseCount：仅月 → 派生窗口计数（count.derived 遮蔽 count.month.derived，
//     断言 count == 列表窗口内命中数）；无筛选 → information_schema 估算
//   - sht：tid 直达 / 单字派生窗口 / 多词 FTS / updated 派生窗口 / hasMagnet /
//     board NULL 回落 cat_name / keyset 锚点 / 封面 MIN(url) 聚合 / 导出分批与 maxThreads
//   - 热评：period+period_key、`rank` 升序、无数据 hasData=false 空态（不抛异常）
//   - taxonomy：索引表优先 + fallback；alt 库（缺 makers/codes/articles 表）验证
//     makers 走 movies 聚合回退、codes 回退被 SqlPolicy 拒绝恒空（已知问题逐字复刻）、
//     articles 缺表抛 QRuntimeError
//
// fixture 规模（主库）：影片 12（中英文混合 / 同日 3 部 / 跨 4 年 / 1 部 NULL 日期 /
//   NULL 番号 / number_letter 字头列全量填充（NULL 番号行 NULL）/ want·score 高低分布）/
//   女优 5（gender 0/1、1 个 merged_into）/ 标签 4 /
//   出演 8 / 磁力 4 / 剧照 4 / TOP250 4 行（榜单年度 2025+2026）/ makers 3 / codes 5 /
//   资讯 3 / 资讯关联 4 / 热评 2 周期 3 批次 7 行 / 帖子 6（board NULL、部分无磁力）/
//   帖磁力 5 / 帖图 4 / ed2k 1 / 视频 1 / sht_sem_meta 1。
//
// 无法断言的口径（原因）：
//   - home per 钳制（per∉12...36 → 24）与 browse OFFSET 钳制值 5000：fixture 行数远小于
//     阈值，外部只能观察"全量/空页"，钳制数值已由 PaginationGuard / 纯单元测试覆盖；
//   - browse 单体标签未解析文案（singleMissing）：标签索引是进程级静态缓存，无法在
//     真实库路径下可靠清空（依赖测试名字典序不可靠）；
//   - 离线 localFallback / 探活失败路径：需要 Db.check 探活失败（坏端口）才能进入，
//     与"真实 MySQL fixture"前提冲突，属离线单元测试范畴；本套件只测成功路径真值；
//   - FULLTEXT 用 MySQL 默认分词（非 ngram）：刻意复刻"中文 0 命中 → 派生表 LIKE 兜底"
//     的生产路径（与提取文档 §1.12 一致）；ngram 行为需 ngram 环境单独验证。

final class QIntegrationTests: XCTestCase {

    static let host = ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_HOST"] ?? "127.0.0.1"
    static let port = Int(ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_PORT"] ?? "3306")!
    static let user = ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_USER"] ?? "root"
    static let pass = ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_PASS"] ?? "root"
    static let dbName = "jdlv_it_q"
    static let altDbName = "jdlv_it_q_alt"   // 稀疏库：缺 makers/codes/articles 表

    static var group: EventLoopGroup!
    static var bootConn: MySQLConnection!

    override class func tearDown() {
        if let c = bootConn, !c.isClosed {
            _ = try? c.close().wait()
        }
        bootConn = nil
    }
    static let bootLock = NSLock()
    static var booted = false

    override class func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func setUpWithError() throws {
        OfflineGate.reset(now: 0)
        SqlPolicy.setEnforceForTesting(true)
    }

    override func tearDownWithError() throws {
        OfflineGate.reset(now: 0)
    }

    // MARK: - fixture 装载

    /// 每条测试入口：Db 指向 fixture 库 + 重置全局状态。
    /// Q 层全部只读（库数据不因测试改变）→ fixture 每个测试类只重建一次，
    /// 逐条测试用 Db.reset()（清池 + 清 schema 探测缓存）隔离连接态。
    @discardableResult
    func boot() async throws -> MySQLPoolSettings {
        let s = MySQLPoolSettings(
            host: Self.host, port: Self.port, user: Self.user, pass: Self.pass,
            jdbDb: Self.dbName, shtDb: Self.dbName, tls: false,
            connectTimeout: 5, queryTimeout: 8)
        Db.configure(settingsProvider: { s }, hasNetwork: { true })
        Db.reset()
        OfflineGate.reset(now: 0)
        JdbSearch.idx = nil
        ShtSearch.shadow = nil
        Q.tagsIndexDataProvider = nil
        try await Self.buildFixtureOnce()
        return s
    }

    static func buildFixtureOnce() async throws {
        bootLock.lock()
        defer { bootLock.unlock() }
        if booted, let c = bootConn, !c.isClosed { return }
        if bootConn == nil || bootConn!.isClosed {
            let addr = try SocketAddress.makeAddressResolvingHost(host, port: port)
            bootConn = try await awaitFuture(
                MySQLConnection.connect(
                    to: addr, username: user, database: "",
                    password: pass, tlsConfiguration: nil, serverHostname: nil,
                    on: group.next()))
        }
        let conn = bootConn!
        for db in [dbName, altDbName] {
            _ = try await awaitFuture(conn.simpleQuery("DROP DATABASE IF EXISTS \(db)"))
            _ = try await awaitFuture(conn.simpleQuery("CREATE DATABASE \(db) CHARACTER SET utf8mb4"))
        }
        _ = try await awaitFuture(conn.simpleQuery("USE \(dbName)"))
        for stmt in schemaStatements {
            _ = try await awaitFuture(conn.simpleQuery(stmt))
        }
        for stmt in seedStatements {
            _ = try await awaitFuture(conn.simpleQuery(stmt))
        }
        _ = try await awaitFuture(conn.simpleQuery("USE \(altDbName)"))
        for stmt in altSchemaStatements {
            _ = try await awaitFuture(conn.simpleQuery(stmt))
        }
        for stmt in altSeedStatements {
            _ = try await awaitFuture(conn.simpleQuery(stmt))
        }
        _ = try await awaitFuture(conn.simpleQuery("USE \(dbName)"))
        booted = true
    }

    /// taxonomy() → rememberRemoteTags → JdbSearch.tagId 文本反查可用（进程级 24h 缓存）。
    /// 标签相关测试都先调用，保证与测试执行顺序无关。
    func loadTagIndex() async {
        _ = await Q.taxonomy()
    }

    // MARK: 取值小助手

    private func rowsOf(_ res: [String: Any], _ key: String) -> [Row] {
        res[key] as? [Row] ?? []
    }

    private func int64Of(_ res: [String: Any], _ key: String) -> Int64 {
        res[key] as? Int64 ?? -99
    }

    // MARK: - fixture schema（主库）

    static let moviesDDL =
        "CREATE TABLE movies (id VARCHAR(32) PRIMARY KEY, number VARCHAR(64), " +
        "number_letter VARCHAR(8), " +
        "title VARCHAR(255), origin_title VARCHAR(255), release_date VARCHAR(20), " +
        "year INT, duration INT, score DECIMAL(4,1), reviews_count INT, " +
        "comments_count INT, want_watch_count INT, watched_count INT, magnets_count INT, " +
        "has_cnsub TINYINT, can_play TINYINT, maker_id VARCHAR(32), maker_name VARCHAR(128), " +
        "director_id VARCHAR(32), director_name VARCHAR(128), publisher_id VARCHAR(32), " +
        "publisher_name VARCHAR(128), series_id VARCHAR(32), series_name VARCHAR(128), " +
        "cover_url TEXT, thumb_url TEXT, summary TEXT, detail_fetched TINYINT, " +
        "images_downloaded TINYINT, FULLTEXT KEY ftx_movies (title, number)) " +
        "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"

    static let movieTagsDDL =
        "CREATE TABLE movie_tags (movie_id VARCHAR(32), tag_id VARCHAR(32), " +
        "tag_name VARCHAR(128), PRIMARY KEY(movie_id, tag_id))"

    static let movieActorsDDL =
        "CREATE TABLE movie_actors (movie_id VARCHAR(32), actor_id VARCHAR(32), " +
        "actor_name VARCHAR(190), PRIMARY KEY(movie_id, actor_id))"

    static let actorsDDL =
        "CREATE TABLE actors (id VARCHAR(32) PRIMARY KEY, name VARCHAR(190), " +
        "gender INT, merged_into VARCHAR(32), avatar_url TEXT, videos_count INT, " +
        "aliases VARCHAR(190), other_name VARCHAR(190), name_zht VARCHAR(190), " +
        "popularity INT, avg_score_all DECIMAL(4,1), avg_score_solo DECIMAL(4,1), " +
        "debut VARCHAR(20))"

    static let magnetsDDL =
        "CREATE TABLE magnets (movie_id VARCHAR(32), hash VARCHAR(64), name VARCHAR(255), " +
        "size VARCHAR(32), cnsub TINYINT, hd TINYINT, files_count INT, created_at DATETIME, " +
        "PRIMARY KEY(movie_id, hash))"

    static let movieImagesDDL =
        "CREATE TABLE movie_images (movie_id VARCHAR(32), url VARCHAR(255), kind VARCHAR(16), " +
        "PRIMARY KEY(movie_id, url))"

    static let rankingsDDL =
        "CREATE TABLE rankings_top250 (section VARCHAR(32), year INT, `rank` INT, " +
        "number VARCHAR(64), movie_id VARCHAR(32), PRIMARY KEY(section, year, `rank`, movie_id))"

    static let makersDDL =
        "CREATE TABLE makers (id VARCHAR(32) PRIMARY KEY, name VARCHAR(128), videos_count INT)"

    static let codesDDL =
        "CREATE TABLE codes (id VARCHAR(32) PRIMARY KEY, name VARCHAR(64), videos_count INT)"

    static let articlesDDL =
        "CREATE TABLE articles (id VARCHAR(32) PRIMARY KEY, title VARCHAR(255), " +
        "category_id INT, category_name VARCHAR(64), author_name VARCHAR(128), " +
        "origin_name VARCHAR(128), origin_url TEXT, cover_url TEXT, cover_path TEXT, " +
        "released_at DATETIME, content_html MEDIUMTEXT, content_text MEDIUMTEXT, word_count INT)"

    static let articleMoviesDDL =
        "CREATE TABLE article_movies (article_id VARCHAR(32), movie_id VARCHAR(32), " +
        "number VARCHAR(64), title VARCHAR(255), score DECIMAL(4,1), release_date VARCHAR(20), " +
        "thumb_url TEXT, position INT, PRIMARY KEY(article_id, movie_id))"

    static let hotReviewsDDL =
        "CREATE TABLE hot_reviews (rid BIGINT PRIMARY KEY, period VARCHAR(16), " +
        "period_key VARCHAR(32), `rank` INT, movie_id VARCHAR(32), number VARCHAR(64), " +
        "movie_title VARCHAR(255), movie_score DECIMAL(4,1), movie_thumb_url TEXT, " +
        "user_name VARCHAR(128), score INT, likes_count INT, content TEXT, created_at DATETIME)"

    static let shtThreadsDDL =
        "CREATE TABLE sht_threads (tid BIGINT UNSIGNED PRIMARY KEY, title VARCHAR(255), " +
        "cat_name VARCHAR(64), board VARCHAR(32), board_name VARCHAR(64), " +
        "`type` VARCHAR(32), post_date DATETIME, last_checked DATETIME, magnet_count INT, " +
        "article_words INT, paywalled TINYINT, author VARCHAR(128), article MEDIUMTEXT, " +
        "FULLTEXT KEY ftx_sht_threads (title)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"

    static let shtMagnetsDDL =
        "CREATE TABLE sht_magnets (tid BIGINT UNSIGNED, hash VARCHAR(64), name VARCHAR(255), " +
        "size VARCHAR(32), first_seen DATETIME, link TEXT, PRIMARY KEY(tid, hash))"

    static let shtThreadImagesDDL =
        "CREATE TABLE sht_thread_images (tid BIGINT UNSIGNED, url VARCHAR(255), " +
        "PRIMARY KEY(tid, url))"

    static let shtThreadEd2kDDL =
        "CREATE TABLE sht_thread_ed2k (tid BIGINT UNSIGNED, url VARCHAR(255), " +
        "name VARCHAR(255), size VARCHAR(32), first_seen DATETIME, PRIMARY KEY(tid, url))"

    static let shtThreadVideosDDL =
        "CREATE TABLE sht_thread_videos (tid BIGINT UNSIGNED, url VARCHAR(255), " +
        "PRIMARY KEY(tid, url))"

    static let shtSemMetaDDL =
        "CREATE TABLE sht_sem_meta (id INT PRIMARY KEY, name VARCHAR(64), dim INT, path VARCHAR(255))"

    static var schemaStatements: [String] {
        [
            moviesDDL, movieTagsDDL, movieActorsDDL, actorsDDL, magnetsDDL,
            movieImagesDDL, rankingsDDL, makersDDL, codesDDL, articlesDDL,
            articleMoviesDDL, hotReviewsDDL, shtThreadsDDL, shtMagnetsDDL,
            shtThreadImagesDDL, shtThreadEd2kDDL, shtThreadVideosDDL, shtSemMetaDDL,
        ]
    }

    static var altSchemaStatements: [String] {
        [moviesDDL, movieTagsDDL]   // 稀疏库：无 makers/codes/actors/articles
    }

    // MARK: - fixture seed（主库）

    static let movieSeeds: [String] = [
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m01','abp-001','abp','演示影片 Alpha','Alpha Origin','2024-01-15',2024,120,8.5,320,900,3,1,0," +
            "'mk1','片商一','dr1','导演甲','pb1','发行商一','sr1','系列一','https://img/c1.jpg','https://img/t1.jpg','剧情简介一')",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m02','abp-002','abp','Demo Two Beta','Beta Origin','2024-01-15',2024,96,7.2,100,120,0,0,1," +
            "'mk1','片商一',NULL,NULL,NULL,NULL,'sr1','系列一',NULL,'https://img/t2.jpg',NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m03','xyz-003','xyz','演示影片 Gamma','Gamma Origin','2023-12-31',2023,150,9.1,800,4500,7,1,1," +
            "'mk2','片商二','dr1','导演甲','pb2','发行商二',NULL,NULL,'https://img/c3.jpg','https://img/t3.jpg','剧情简介三')",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m04',NULL,NULL,'无番号影片',NULL,NULL,2022,NULL,NULL,NULL,0,0,0,0," +
            "NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m05','abp-010','abp','单体作品 Delta demo',NULL,'2025-03-10',2025,110,6.8,50,300,2,0,0," +
            "'mk2','片商二',NULL,NULL,NULL,NULL,NULL,NULL,'https://img/c5.jpg','https://img/t5.jpg',NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m06','cdx-004','cdx','Cdx Four demo',NULL,'2024-06-20',2024,88,5.5,30,60,1,0,0," +
            "'mk1','片商一',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'https://img/t6.jpg',NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m07','abp-003','abp','演示影片 Epsilon',NULL,'2024-03-05',2024,130,8.0,260,2000,5,1,1," +
            "'mk1','片商一','dr2','导演乙','pb1','发行商一','sr2','系列二',NULL,'https://img/t7.jpg',NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m08','abp-030','abp','演示影片 Kappa',NULL,'2024-09-09',2024,92,6.3,45,210,0,0,0," +
            "'mk3','片商三',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m09','xyz-007','xyz','Historical drama Seven',NULL,'2022-07-01',2022,100,6.0,40,25,0,0,0," +
            "'mk2','片商二',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m10','abp-020','abp','演示影片 Zeta',NULL,'2024-01-15',2024,95,7.7,210,700,4,1,0," +
            "'mk1','片商一',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'https://img/t10.jpg',NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m11','deep-001','deep','Deep One Iota',NULL,'2023-05-15',2023,105,6.9,55,150,1,0,0," +
            "NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)",
        "INSERT INTO movies (id, number, number_letter, title, origin_title, release_date, year, duration, " +
            "score, reviews_count, want_watch_count, magnets_count, has_cnsub, can_play, " +
            "maker_id, maker_name, director_id, director_name, publisher_id, publisher_name, " +
            "series_id, series_name, cover_url, thumb_url, summary) VALUES " +
            "('m12','fgh-002','fgh','演示影片 Theta',NULL,'2025-01-01',2025,140,8.8,410,3300,6,1,1," +
            "'mk2','片商二','dr1','导演甲','pb2','发行商二',NULL,NULL,NULL,'https://img/t12.jpg','剧情简介十二')",
    ]

    static let tagSeeds: [String] = [
        "INSERT INTO movie_tags VALUES ('m01','t1','巨乳'),('m01','t2','人妻')," +
            "('m03','t1','巨乳'),('m03','t3','單體作品')," +
            "('m05','t3','單體作品'),('m05','t4','制服'),('m12','t4','制服')",
    ]

    static let actorLinkSeeds: [String] = [
        "INSERT INTO movie_actors VALUES ('m01','a1','女优甲'),('m01','a2','女优乙')," +
            "('m03','a1','女优甲'),('m03','a3','女优丙'),('m05','a3','女优丙')," +
            "('m07','a3','女优丙'),('m07','a2','女优乙'),('m12','a1','女优甲')",
    ]

    static var seedStatements: [String] {
        [
            // 女优（gender 0/1；a5 merged_into 非空；avg 有 NULL/0 沉底样本）
            "INSERT INTO actors VALUES " +
                "('a1','女优甲',0,NULL,NULL,12,'甲alias','甲other','女優甲',88,8.2,7.9,'2015-04-01')," +
                "('a2','女优乙',1,NULL,NULL,5,NULL,NULL,NULL,10,NULL,NULL,NULL)," +
                "('a3','女优丙',0,NULL,NULL,30,'丙alias',NULL,'女優丙',95,9.0,9.1,'2012-01-01')," +
                "('a4','女优丁',0,NULL,NULL,11,NULL,NULL,NULL,5,0,0,NULL)," +
                "('a5','已合并女优',0,'a1',NULL,99,NULL,NULL,NULL,1,5.0,5.0,'2010-01-01')",
            // 磁力
            "INSERT INTO magnets VALUES ('m01','hashm01a','Alpha magnet one','1.20 GiB',1,1,1,'2024-02-01 10:00:00')," +
                "('m01','hashm01b','Alpha magnet two','0.80 GiB',0,0,2,'2024-02-02 11:00:00')," +
                "('m03','hashm03a','Gamma magnet','2.40 GiB',1,1,3,'2024-01-05 09:00:00')," +
                "('m05','hashm05a','Delta magnet','1.00 GiB',0,1,1,'2025-03-11 08:00:00')",
            // 剧照（cover 行不得混入 previews）
            "INSERT INTO movie_images VALUES " +
                "('m01','https://img/p1.jpg','preview'),('m01','https://img/p2.jpg','preview')," +
                "('m01','https://img/cover1.jpg','cover'),('m03','https://img/p3.jpg','preview')",
            // TOP250（榜单年度 2026/2025 两个；rank 反引号）
            "INSERT INTO rankings_top250 (section, year, `rank`, number, movie_id) VALUES " +
                "('all',2026,1,'xyz-003','m03'),('all',2026,2,'abp-001','m01')," +
                "('all',2025,3,'fgh-002','m12'),('all',2025,4,'abp-003','m07')",
            // 索引表（taxonomy 主路）
            "INSERT INTO makers VALUES ('mk1','片商一',5),('mk2','片商二',4),('mk3','片商三',1)",
            "INSERT INTO codes VALUES ('c1','abp',6),('c2','xyz',2),('c3','cdx',1),('c4','deep',1),('c5','fgh',1)",
            // 资讯
            "INSERT INTO articles (id, title, category_id, category_name, author_name, " +
                "origin_name, origin_url, cover_url, cover_path, released_at, content_html, " +
                "content_text, word_count) VALUES " +
                "('art1','资讯标题 Alpha',1,'业界动态','作者甲','来源一','https://src/1','https://img/a1.jpg','/p/a1.jpg'," +
                "'2025-06-01 10:00:00','<p>Alpha 正文 abp-001</p>','Alpha 正文 abp-001',100)," +
                "('art2','演示资讯 Beta',1,'业界动态','作者乙','来源二','https://src/2',NULL,NULL," +
                "'2025-05-01 09:00:00','<p>Beta 正文 abp-002</p>','Beta 正文 abp-002',90)," +
                "('art3','Gamma News Three',2,'作品评测','作者丙','来源三','https://src/3',NULL,NULL," +
                "'2025-04-01 08:00:00','<p>xyz-003 review</p>','xyz-003 review',80)",
            "INSERT INTO article_movies VALUES " +
                "('art1','m01','abp-001','演示影片 Alpha',8.5,'2024-01-15','https://img/t1.jpg',1)," +
                "('art1','m03','xyz-003','演示影片 Gamma',9.1,'2023-12-31','https://img/t3.jpg',2)," +
                "('art2','m02','abp-002','Demo Two Beta',7.2,'2024-01-15','https://img/t2.jpg',1)," +
                "('art3','m03','xyz-003','演示影片 Gamma',9.1,'2023-12-31','https://img/t3.jpg',1)",
            // 热评（2 周期 / day 2 批次 / rank 反引号）
            "INSERT INTO hot_reviews (rid, period, period_key, `rank`, movie_id, number, " +
                "movie_title, movie_score, movie_thumb_url, user_name, score, likes_count, " +
                "content, created_at) VALUES " +
                "(1,'day','2025-06-01',1,'m03','xyz-003','演示影片 Gamma',9.1,'https://img/t3.jpg','userA',5,120,'神作','2025-06-01 12:00:00')," +
                "(2,'day','2025-06-01',2,'m01','abp-001','演示影片 Alpha',8.5,'https://img/t1.jpg','userB',4,80,'好评','2025-06-01 12:05:00')," +
                "(3,'day','2025-06-01',3,'m12','fgh-002','演示影片 Theta',8.8,'https://img/t12.jpg','userC',5,200,'顶','2025-06-01 12:10:00')," +
                "(4,'day','2025-05-31',1,'m07','abp-003','演示影片 Epsilon',8.0,'https://img/t7.jpg','userA',4,30,'不错','2025-05-31 09:00:00')," +
                "(5,'day','2025-05-31',2,'m05','abp-010','单体作品 Delta demo',6.8,'https://img/t5.jpg','userD',3,10,'一般','2025-05-31 09:05:00')," +
                "(6,'week','2025-W23',1,'m07','abp-003','演示影片 Epsilon',8.0,'https://img/t7.jpg','userE',5,45,'周榜第一','2025-06-02 08:00:00')," +
                "(7,'week','2025-W23',2,'m01','abp-001','演示影片 Alpha',8.5,'https://img/t1.jpg','userF',4,22,'周榜第二','2025-06-02 08:05:00')",
            // 98t 帖子（board NULL 一条；无磁力两条；article JSON 一条）
            "INSERT INTO sht_threads (tid, title, cat_name, board, board_name, `type`, post_date, " +
                "last_checked, magnet_count, article_words, paywalled, author, article) VALUES " +
                "(1001,'Tokyo Hot Collection','有码原创','tc','亚洲无码原创','磁力链接','2025-06-01 12:00:00','2025-06-02 08:00:00',3,500,0,'userA'," +
                "'[{\"t\":\"第一段正文\"},{\"i\":\"https://img/x1.jpg\",\"sz\":120}]')," +
                "(1002,'Demo Magnet Post Two','有码原创','tc','亚洲无码原创','磁力链接','2025-05-20 10:00:00','2025-05-21 09:00:00',1,300,0,'userB','普通文本正文')," +
                "(1003,'国产精选合集','国产原创',NULL,'国产原创','磁力链接','2025-05-15 09:00:00','2025-05-16 09:00:00',2,200,0,'userC','')," +
                "(1004,'Photo Thread Four','台湾论坛','tw','台湾论坛','图片区','2025-04-10 08:00:00',NULL,0,50,0,'userD',NULL)," +
                "(1005,'字幕发布 Five','有码原创','tc','亚洲无码原创','字幕','2025-03-20 07:00:00','2025-03-21 07:00:00',0,80,0,'userE','字幕说明文本')," +
                "(1006,'Euro Collection Six','欧洲原创','eu','欧洲原创','磁力链接','2025-02-01 06:00:00','2025-07-01 10:00:00',5,150,0,'userF',NULL)",
            "INSERT INTO sht_magnets (tid, hash, name, size, first_seen, link) VALUES " +
                "(1001,'hashs1a','coll part1.torrent','4.30 GiB','2025-06-01 12:05:00',NULL)," +
                "(1001,'hashs1b','coll part2.torrent','1.00 GiB','2025-06-01 12:06:00','magnet:?xt=urn:btih:hashs1b&dn=x')," +
                "(1002,'hashs2a','demo.torrent','0.50 GiB','2025-05-20 10:05:00',NULL)," +
                "(1003,'hashs3a','guochan.torrent','2.00 GiB','2025-05-15 09:05:00',NULL)," +
                "(1006,'hashs6a','euro.torrent','3.00 GiB','2025-02-01 06:05:00',NULL)",
            "INSERT INTO sht_thread_images VALUES " +
                "(1001,'https://img/s1a.jpg'),(1001,'https://img/s1b.jpg')," +
                "(1003,'https://img/s3a.jpg'),(1004,'https://img/s4a.jpg')",
            "INSERT INTO sht_thread_ed2k VALUES " +
                "(1001,'ed2k://|file|coll.mp4|1468006400|ABCD|','coll.mp4','1.40 GiB','2025-06-01 12:10:00')",
            "INSERT INTO sht_thread_videos VALUES (1001,'https://vid/v1.mp4')",
            "INSERT INTO sht_sem_meta VALUES (1,'minilm',384,'/models/minilm.onnx')",
        ] + movieSeeds + tagSeeds + actorLinkSeeds
    }

    static var altSeedStatements: [String] {
        movieSeeds + tagSeeds
    }

    // MARK: - B.1 movieCols

    func test_Q_movieCols_fullProbeList() async throws {
        try await boot()
        let cols = await Q.movieCols()
        // 列探测非空 → CARD_BASE + CARD_OPT 全量（fixture 覆盖全部 12 列）
        XCTAssertEqual(
            cols,
            "m.id, m.number, m.title, m.release_date, m.score, m.duration, " +
                "m.magnets_count, m.want_watch_count, m.cover_url, m.year, m.number_letter, m.has_cnsub")
        let __a1 = try await Q.movieCols(prefix: "x").hasPrefix("x.id, ")
        XCTAssertEqual(__a1, true)
    }

    // MARK: - B.6 home

    func test_Q_home_threeSegmentsOrder() async throws {
        try await boot()
        let res = try await Q.home()
        let recent = rowsOf(res, "recent")
        let hot = rowsOf(res, "hot")
        let top = rowsOf(res, "top")
        XCTAssertEqual(recent.count, 12)
        XCTAssertEqual(hot.count, 12)
        XCTAssertEqual(top.count, 4)
        XCTAssertEqual(recent.first?.s("id"), "m05")   // release_date DESC → 2025-03-10
        XCTAssertEqual(hot.first?.s("id"), "m03")      // want 4500
        XCTAssertEqual(top.first?.s("id"), "m03")      // rank 1（`rank` 反引号 ASC）
        XCTAssertEqual(top.first?.i("rank"), 1)
        XCTAssertEqual(top.last?.s("id"), "m07")       // rank 4
        XCTAssertNil(res["derived"], "远程成功路径无 derived 键")
    }

    func test_Q_home_perParameterized() async throws {
        try await boot()
        let res = try await Q.home(per: 13)   // 12...36 内 → eff=13 → 表只有 12 行
        XCTAssertEqual(rowsOf(res, "recent").count, 12)
        XCTAssertEqual(rowsOf(res, "hot").count, 12)
        XCTAssertEqual(rowsOf(res, "top").count, 4)
        let res2 = try await Q.home(per: 5)   // 区间外 → eff=24 → 仍然 12 行（钳制数值由单元测试覆盖）
        XCTAssertEqual(rowsOf(res2, "recent").count, 12)
    }

    // MARK: - B.7 top250 / B.8 top250Years

    func test_Q_top250_page1RankOrder() async throws {
        try await boot()
        let res = try await Q.top250()
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("id") }, ["m03", "m01", "m12", "m07"])
        XCTAssertEqual(int64Of(res, "total"), 4)
        XCTAssertEqual(res["page"] as? Int, 1)
        XCTAssertEqual(res["per"] as? Int, 40)
        XCTAssertEqual(res["year"] as? String, "")
        XCTAssertEqual(items.first?.i("rank"), 1)
    }

    func test_Q_top250_yearFilter() async throws {
        try await boot()
        let res = try await Q.top250(year: "2024")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("id") }, ["m01", "m07"])   // movies.year 而非榜单年度
        XCTAssertEqual(int64Of(res, "total"), 2)
        XCTAssertEqual(res["year"] as? String, "2024")
    }

    func test_Q_top250_page2() async throws {
        try await boot()
        let res = try await Q.top250(page: 2, per: 3)
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m07"])
        XCTAssertEqual(int64Of(res, "total"), 4)
    }

    func test_Q_top250_deepPageNoClamp() async throws {
        try await boot()
        // top250 OFFSET 无钳制（与 browse 的 5000 钳制不同）——深页返回空但不报错
        let res = try await Q.top250(page: 9999)
        XCTAssertTrue(rowsOf(res, "items").isEmpty)
        XCTAssertEqual(int64Of(res, "total"), 4)
    }

    func test_Q_top250Years_distribution() async throws {
        try await boot()
        let rows = await Q.top250Years()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.i("year"), 2025)
        XCTAssertEqual(rows.first?.i("c"), 1)
        let byYear = Dictionary(uniqueKeysWithValues: rows.map { ($0.i("year"), $0.i("c")) })
        XCTAssertEqual(byYear[2024], 2)
        XCTAssertEqual(byYear[2023], 1)
    }

    // MARK: - B.9 search（委托 JdbSearch）

    func test_Q_search_numberPrefixOrder() async throws {
        try await boot()
        let res = try await Q.search(q: "abp", scope: "number", page: 1, per: 10)
        let items = rowsOf(res, "items")
        // ORDER BY m.number, m.id —— idx_movies_number 序
        XCTAssertEqual(items.map { $0.s("id") }, ["m01", "m02", "m07", "m05", "m10", "m08"])
        XCTAssertEqual(int64Of(res, "total"), -1, "COUNT 口径：total=-1 由 searchCount 异步补")
        XCTAssertEqual(res["approx"] as? Bool, true)
        XCTAssertEqual(res["served"] as? String, "remote")
        XCTAssertEqual(res["derived"] as? String, "")
    }

    func test_Q_search_numberPage2() async throws {
        try await boot()
        let res = try await Q.search(q: "abp", scope: "number", page: 2, per: 3)
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m05", "m10", "m08"])
    }

    func test_Q_search_numberExactMode() async throws {
        try await boot()
        let res = try await Q.search(q: "ABP-001", scope: "number", page: 1, per: 10, mode: "exact")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.count, 6, "number='abp001' OR LIKE 'abp%' → 全部 abp 部")
        XCTAssertEqual(items.first?.s("id"), "m05")   // release_date DESC, id DESC
        XCTAssertEqual(res["derived"] as? String, "精确匹配 · 番号/前缀")
    }

    func test_Q_search_ftsTitleEnglish() async throws {
        try await boot()
        let res = try await Q.search(q: "demo", scope: "title", page: 1, per: 10)
        let items = rowsOf(res, "items")
        // MATCH(m.title, m.number) AGAINST('+demo') → m02/m05/m06，release_date DESC
        XCTAssertEqual(items.map { $0.s("id") }, ["m05", "m06", "m02"])
    }

    func test_Q_search_titleFallsBackToDerived() async throws {
        try await boot()
        let res = try await Q.search(q: "演示", scope: "title", page: 1, per: 10)
        let items = rowsOf(res, "items")
        // 默认全文分词切不出中文 → FTS 0 命中 → 最近 5000 部派生表 LIKE 兜底
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.first?.s("id"), "m12")
        XCTAssertEqual(res["derived"] as? String, "已限定最近 5000 部（本地索引未就绪）")
    }

    func test_Q_search_titleExactDerived() async throws {
        try await boot()
        let res = try await Q.search(q: "Demo Two Beta", scope: "title", page: 1, per: 10, mode: "exact")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("id") }, ["m02"])
        XCTAssertTrue((res["derived"] as? String ?? "").contains("已限定最近 5000 部内"))
    }

    func test_Q_search_actorScope() async throws {
        try await boot()
        let res = try await Q.search(q: "女优丙", scope: "actor", page: 1, per: 10)
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("id") }, ["m05", "m07", "m03"])
    }

    func test_Q_search_actorExact() async throws {
        try await boot()
        let res = try await Q.search(q: "女优丙", scope: "actor", page: 1, per: 10, mode: "exact")
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m05", "m07", "m03"])
    }

    func test_Q_search_tagScope() async throws {
        try await boot()
        await loadTagIndex()
        let res = try await Q.search(q: "制服", scope: "tag", page: 1, per: 10)
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("id") }, ["m05", "m12"])   // release_date DESC, id DESC
    }

    func test_Q_search_tagUnknownText() async throws {
        try await boot()
        await loadTagIndex()
        let res = try await Q.search(q: "不存在的标签xx", scope: "tag", page: 1, per: 10)
        // tagId 反查不到 → 空页（绝不退化为 tag_name 全表扫）
        XCTAssertTrue(rowsOf(res, "items").isEmpty)
    }

    func test_Q_search_allUnion() async throws {
        try await boot()
        let res = try await Q.search(q: "abp", scope: "all", page: 1, per: 10)
        let items = rowsOf(res, "items")
        // 三路 UNION DISTINCT（number 6 ∪ fts 6 ∪ actor 0）→ release_date DESC, id DESC
        XCTAssertEqual(items.map { $0.s("id") }, ["m05", "m08", "m07", "m10", "m02", "m01"])
    }

    func test_Q_search_letterScope() async throws {
        try await boot()
        let res = try await Q.search(q: "abp", scope: "letter", page: 1, per: 10)
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m01", "m02", "m07", "m05", "m10", "m08"])
    }

    func test_Q_search_deepPageEmpty() async throws {
        try await boot()
        let res = try await Q.search(q: "abp", scope: "number", page: 7, per: 1000)
        // OFFSET (7-1)*1000=6000 > 5000 → 跳页过深空页
        XCTAssertTrue(rowsOf(res, "items").isEmpty)
        XCTAssertTrue((res["derived"] as? String ?? "").contains("跳页过深"))
    }

    func test_Q_search_emptyQuery() async throws {
        try await boot()
        let res = try await Q.search(q: "  ", scope: "all", page: 1, per: 10)
        XCTAssertTrue(rowsOf(res, "items").isEmpty)
        XCTAssertEqual(res["page"] as? Int, 1)
    }

    // MARK: - B.10 searchCount

    func test_Q_searchCount_scopes() async throws {
        try await boot()
        await loadTagIndex()
        let __a2 = try await Q.searchCount(q: "abp", scope: "number")
        XCTAssertEqual(__a2, 6)
        let __a3 = try await Q.searchCount(q: "abp", scope: "letter")
        XCTAssertEqual(__a3, 6)
        let __a4 = try await Q.searchCount(q: "demo", scope: "title")
        XCTAssertEqual(__a4, 3)
        let __a5 = try await Q.searchCount(q: "女优丙", scope: "actor")
        XCTAssertEqual(__a5, 3)
        let __a6 = try await Q.searchCount(q: "巨乳", scope: "tag")
        XCTAssertEqual(__a6, 2)
        let __a7 = try await Q.searchCount(q: "abp", scope: "all")
        XCTAssertEqual(__a7, 6)
        let __a8 = try await Q.searchCount(q: "", scope: "all")
        XCTAssertEqual(__a8, 0, "空查询 → 0")
        let __a9 = try await Q.searchCount(q: "zzz-none", scope: "all")
        XCTAssertEqual(__a9, 0, "全路 0 命中 → 派生窗口计数 0")
    }

    // MARK: - B.13 browse

    func test_Q_browse_noFilterFirstPageAndAnchor() async throws {
        try await boot()
        let res = try await Q.browse(f: Filters(), page: 1, per: 4, sort: "release_date")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("id") }, ["m05", "m12", "m08", "m06"])
        XCTAssertEqual(int64Of(res, "total"), -1, "browse COUNT 口径恒 -1")
        XCTAssertEqual(res["approx"] as? Bool, true)
        XCTAssertEqual(res["served"] as? String, "remote")
        XCTAssertEqual(res["derived"] as? String, "")
        XCTAssertEqual(res["page"] as? Int, 1)
        let anchor = res["anchor"] as? [String]
        XCTAssertEqual(anchor?.count, 2)
        XCTAssertEqual(anchor?.last, "m06")
        XCTAssertEqual(anchor?.first, "2024-06-20")
    }

    func test_Q_browse_keysetContinuation() async throws {
        try await boot()
        let p1 = try await Q.browse(f: Filters(), page: 1, per: 3, sort: "release_date")
        let anchor = try XCTUnwrap(p1["anchor"] as? [String])
        let p2 = try await Q.browse(f: Filters(), page: 2, per: 3, sort: "release_date", anchor: anchor)
        XCTAssertEqual(rowsOf(p2, "items").map { $0.s("id") }, ["m06", "m07", "m10"])
        let p1ids = Set(rowsOf(p1, "items").map { $0.s("id") })
        let p2ids = Set(rowsOf(p2, "items").map { $0.s("id") })
        XCTAssertTrue(p1ids.isDisjoint(with: p2ids), "keyset 续页不得与首页重复")
    }

    func test_Q_browse_yearFilter() async throws {
        try await boot()
        let res = try await Q.browse(f: Filters(year: "2024"), page: 1, per: 10, sort: "release_date")
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m08", "m06", "m07", "m10", "m02", "m01"])
        let __a10 = try await Q.browseCount(f: Filters(year: "2024"), sort: "release_date")
        XCTAssertEqual(__a10, 6)
    }

    func test_Q_browse_yearMonthHalfOpen() async throws {
        try await boot()
        let res = try await Q.browse(f: Filters(year: "2024", month: "1"), page: 1, per: 10, sort: "release_date")
        // [2024-01-01, 2024-02-01) 同日 3 部 → id DESC
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m10", "m02", "m01"])
        let __a11 = try await Q.browseCount(f: Filters(year: "2024", month: "1"), sort: "release_date")
        XCTAssertEqual(__a11, 3)
    }

    func test_Q_browse_monthOnlyDerivedWindow() async throws {
        try await boot()
        let f = Filters(month: "1")
        let res = try await Q.browse(f: f, page: 1, per: 10, sort: "release_date")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first?.s("id"), "m12")
        XCTAssertEqual(res["derived"] as? String, "月份筛选已限定最近 20000 部内")
        // ★ count.month.derived 遮蔽语义：仅月计数走同一派生窗口（20000 ⊇ 全表 12 行）
        //   → count 必须等于列表窗口内命中数
        let __a12 = try await Q.browseCount(f: f, sort: "release_date")
        XCTAssertEqual(__a12, Int64(items.count))
    }

    func test_Q_browse_letterPrefixLowercased() async throws {
        try await boot()
        let res = try await Q.browse(f: Filters(letter: "ABP"), page: 1, per: 10, sort: "release_date")
        XCTAssertEqual(rowsOf(res, "items").count, 6)
        XCTAssertEqual(rowsOf(res, "items").first?.s("id"), "m05")
        let __a13 = try await Q.browseCount(f: Filters(letter: "ABP"), sort: "release_date")
        XCTAssertEqual(__a13, 6)
    }

    func test_Q_browse_maker() async throws {
        try await boot()
        let res = try await Q.browse(f: Filters(maker: "mk1"), page: 1, per: 10, sort: "release_date")
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m06", "m07", "m10", "m02", "m01"])
        let __a14 = try await Q.browseCount(f: Filters(maker: "mk1"), sort: "release_date")
        XCTAssertEqual(__a14, 5)
    }

    func test_Q_browse_tagsAnd() async throws {
        try await boot()
        await loadTagIndex()
        let res = try await Q.browse(f: Filters(tags: "巨乳,人妻"), page: 1, per: 10, sort: "release_date")
        // 多标签 AND 语义：同时含 t1+t2 → 仅 m01
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m01"])
        let __a15 = try await Q.browseCount(f: Filters(tags: "巨乳,人妻"), sort: "release_date")
        XCTAssertEqual(__a15, 1)
    }

    func test_Q_browse_magnet() async throws {
        try await boot()
        let res = try await Q.browse(f: Filters(magnet: true), page: 1, per: 10, sort: "release_date")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(items.first?.s("id"), "m05")
        let __a16 = try await Q.browseCount(f: Filters(magnet: true), sort: "release_date")
        XCTAssertEqual(__a16, 8)
    }

    func test_Q_browse_singleTagIds() async throws {
        try await boot()
        await loadTagIndex()
        let res = try await Q.browse(f: Filters(single: true), page: 1, per: 10, sort: "release_date")
        // 单体 = tag_id IN（單體作品→t3；单体作品 简体不在索引 → compactMap 丢弃）
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m05", "m03"])
        let __a17 = try await Q.browseCount(f: Filters(single: true), sort: "release_date")
        XCTAssertEqual(__a17, 2)
    }

    func test_Q_browse_seriesDerivedWindow() async throws {
        try await boot()
        let res = try await Q.browse(f: Filters(seriesId: "sr1"), page: 1, per: 10, sort: "release_date")
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m02", "m01"])
        XCTAssertEqual(res["derived"] as? String, "反查已限定最近 20000 部内 · 可在设置切全库")
    }

    func test_Q_browse_directorAndPublisher() async throws {
        try await boot()
        let d = try await Q.browse(f: Filters(directorId: "dr1"), page: 1, per: 10, sort: "release_date")
        XCTAssertEqual(rowsOf(d, "items").map { $0.s("id") }, ["m12", "m01", "m03"])
        let __a18 = try await Q.browseCount(f: Filters(directorId: "dr1"), sort: "release_date")
        XCTAssertEqual(__a18, 3)
        let p = try await Q.browse(f: Filters(publisherId: "pb1"), page: 1, per: 10, sort: "release_date")
        XCTAssertEqual(rowsOf(p, "items").map { $0.s("id") }, ["m07", "m01"])
        let __a19 = try await Q.browseCount(f: Filters(publisherId: "pb1"), sort: "release_date")
        XCTAssertEqual(__a19, 2)
    }

    func test_Q_browse_comboFilters() async throws {
        try await boot()
        let f = Filters(year: "2024", magnet: true, cnsub: true)
        let res = try await Q.browse(f: f, page: 1, per: 10, sort: "release_date")
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["m07", "m10", "m01"])
        let __a20 = try await Q.browseCount(f: f, sort: "release_date")
        XCTAssertEqual(__a20, 3)
    }

    func test_Q_browse_sortFourKeysAscDesc() async throws {
        try await boot()
        // id（收录顺序，单列稳定序）
        let __r1 = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "id", asc: true)
        XCTAssertEqual(rowsOf(__r1, "items").first?.s("id"), "m01")
        let __r2 = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "id", asc: false)
        XCTAssertEqual(rowsOf(__r2, "items").first?.s("id"), "m12")
        // score（needsDerived + 次键 reviews_count；NULL 沉 asc 首位）
        let scoreDesc = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "score", asc: false)
        XCTAssertEqual(rowsOf(scoreDesc, "items").first?.s("id"), "m03")
        XCTAssertEqual(scoreDesc["derived"] as? String, "已限定最近 5000 部内按评分排序")
        let __r3 = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "score", asc: true)
        XCTAssertEqual(rowsOf(__r3, "items").first?.s("id"), "m04")
        // want_watch_count
        let __r4 = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "want_watch_count", asc: false)
        XCTAssertEqual(rowsOf(__r4, "items").first?.s("id"), "m03")
        let __r5 = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "want_watch_count", asc: true)
        XCTAssertEqual(rowsOf(__r5, "items").first?.s("id"), "m04")
        // release_date（asc → NULL 日期沉首位）
        let __r6 = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "release_date", asc: true)
        XCTAssertEqual(rowsOf(__r6, "items").first?.s("id"), "m04")
        let __r7 = try await Q.browse(f: Filters(), page: 1, per: 12, sort: "release_date", asc: false)
        XCTAssertEqual(rowsOf(__r7, "items").first?.s("id"), "m05")
    }

    func test_Q_browse_offsetClamp() async throws {
        try await boot()
        // page=999, per=10 → rawOffset=9980 → 钳到 5000 → 空页（钳制数值由单元测试覆盖）
        let res = try await Q.browse(f: Filters(), page: 999, per: 10, sort: "release_date")
        XCTAssertTrue(rowsOf(res, "items").isEmpty)
        XCTAssertEqual(res["page"] as? Int, 999)
        XCTAssertTrue(res["anchor"] is NSNull, "空页 anchor = null")
    }

    // MARK: - B.14 browseCount

    func test_Q_browseCount_estimateAndFailClosed() async throws {
        try await boot()
        // 无筛选 → information_schema TABLE_ROWS 估算（小表精确；"约 N 部"）
        let est = await Q.browseCount(f: Filters(), sort: "release_date")
        XCTAssertGreaterThanOrEqual(est, 12)
        // 标签文本反查不到 → WHERE 1=0 → 0（fail-closed）
        let __a21 = try await Q.browseCount(f: Filters(tags: "不存在的标签xx"), sort: "release_date")
        XCTAssertEqual(__a21, 0)
    }

    // MARK: - B.16 movie

    func test_Q_movie_detailBuckets() async throws {
        try await boot()
        let m = try await Q.movie(mid: "m01")
        XCTAssertEqual(m?["id"] as? String, "m01")
        XCTAssertEqual(m?["number"] as? String, "abp-001")
        XCTAssertEqual(m?["title"] as? String, "演示影片 Alpha")
        XCTAssertEqual(m?["origin_title"] as? String, "Alpha Origin", "详情列清单含 origin_title")
        XCTAssertEqual(m?["score"] as? Double ?? 0, 8.5, accuracy: 0.001)
        XCTAssertEqual(m?["year"] as? Int64, 2024)
        XCTAssertEqual(m?["summary"] as? String, "剧情简介一")
        // tags（PK(movie_id,tag_id) 序）
        let tags = m?["tags"] as? [Row] ?? []
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags.first?.s("tag_id"), "t1")
        XCTAssertEqual(tags.first?.s("tag_name"), "巨乳")
        // actors：gender==1 男沉底（稳定分区）
        let actors = m?["actors"] as? [[String: Any]] ?? []
        XCTAssertEqual(actors.count, 2)
        XCTAssertEqual(actors.first?["actor_id"] as? String, "a1")
        XCTAssertEqual(actors.first?["gender"] as? Int64, 0)
        XCTAssertEqual(actors.last?["actor_id"] as? String, "a2")
        XCTAssertEqual(actors.last?["gender"] as? Int64, 1)
        // magnets
        let magnets = m?["magnets"] as? [Row] ?? []
        XCTAssertEqual(magnets.count, 2)
        XCTAssertEqual(magnets.first?.s("hash"), "hashm01a")
        XCTAssertEqual(magnets.first?.s("size"), "1.20 GiB")
        XCTAssertEqual(magnets.first?.b("cnsub"), true)
        // previews：仅 kind='preview'（cover 行排除）
        XCTAssertEqual(m?["previews"] as? [String], ["https://img/p1.jpg", "https://img/p2.jpg"])
        // jrow null 语义：NULL 列 → NSNull
        XCTAssertTrue(m?["comments_count"] is NSNull)
    }

    func test_Q_movie_missingReturnsNil() async throws {
        try await boot()
        let m = try await Q.movie(mid: "nope")
        XCTAssertNil(m)
    }

    // MARK: - B.17 movieByNumber

    func test_Q_movieByNumber_exactAndTrim() async throws {
        try await boot()
        let __a22 = try await Q.movieByNumber(number: "abp-001")?.s("id")
        XCTAssertEqual(__a22, "m01")
        let __a23 = try await Q.movieByNumber(number: " abp-001 ")?.s("id")
        XCTAssertEqual(__a23, "m01", "入参 trim")
        let __a24 = try await Q.movieByNumber(number: " abp-001 ")?.s("number")
        XCTAssertEqual(__a24, "abp-001")
        let __v = try await Q.movieByNumber(number: "zzz-999")
        XCTAssertNil(__v)
    }

    // MARK: - B.4 movieCovers

    func test_Q_movieCovers_dedupAndSkipBlankCover() async throws {
        try await boot()
        let map = await Q.movieCovers(ids: ["m01", "m03", "m02", "m01"])
        XCTAssertEqual(map.count, 2, "去重 + NULL 封面跳过")
        XCTAssertEqual(map["m01"], "https://img/c1.jpg")
        XCTAssertEqual(map["m03"], "https://img/c3.jpg")
        XCTAssertNil(map["m02"])
        let empty = await Q.movieCovers(ids: [])
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - B.18 actors

    func test_Q_actors_videosSortAndPagination() async throws {
        try await boot()
        let p1 = try await Q.actors(sort: "videos", q: "", page: 1, per: 2, gender: "")
        let items1 = rowsOf(p1, "items")
        XCTAssertEqual(items1.map { $0.s("id") }, ["a3", "a1"])
        XCTAssertEqual(int64Of(p1, "total"), -1, "actors COUNT 口径 -1（异步 actorsCount）")
        XCTAssertEqual(p1["approx"] as? Bool, true)
        let p2 = try await Q.actors(sort: "videos", q: "", page: 2, per: 2, gender: "")
        XCTAssertEqual(rowsOf(p2, "items").map { $0.s("id") }, ["a4", "a2"])
        let p3 = try await Q.actors(sort: "videos", q: "", page: 99, per: 2, gender: "")
        XCTAssertTrue(rowsOf(p3, "items").isEmpty, "OFFSET 无钳制 → 深页空")
    }

    func test_Q_actors_genderAndQuery() async throws {
        try await boot()
        let f = try await Q.actors(sort: "videos", q: "", page: 1, per: 10, gender: "f")
        XCTAssertEqual(rowsOf(f, "items").map { $0.s("id") }, ["a3", "a1", "a4"], "gender<>1 且 merged_into 已合并排除")
        let m = try await Q.actors(sort: "videos", q: "", page: 1, per: 10, gender: "m")
        XCTAssertEqual(rowsOf(m, "items").map { $0.s("id") }, ["a2"])
        let q = try await Q.actors(sort: "videos", q: "女优丙", page: 1, per: 10, gender: "")
        XCTAssertEqual(rowsOf(q, "items").map { $0.s("id") }, ["a3"])
    }

    func test_Q_actors_avgAndDebutSort() async throws {
        try await boot()
        let avg = try await Q.actors(sort: "avg_all", q: "", page: 1, per: 10, gender: "")
        // NULL/0 沉底：(avg IS NULL OR avg=0) ASC, avg DESC → a3, a1, a4, a2
        XCTAssertEqual(rowsOf(avg, "items").map { $0.s("id") }, ["a3", "a1", "a4", "a2"])
        let debut = try await Q.actors(sort: "debut", q: "", page: 1, per: 10, gender: "")
        XCTAssertEqual(rowsOf(debut, "items").first?.s("id"), "a3", "debut 最早在前，NULL 沉底")
        let pop = try await Q.actors(sort: "popularity", q: "", page: 1, per: 10, gender: "")
        XCTAssertEqual(rowsOf(pop, "items").map { $0.s("id") }, ["a3", "a1", "a2", "a4"])
    }

    // MARK: - B.19 actorsCount

    func test_Q_actorsCount_genderAndQuery() async throws {
        try await boot()
        let __a25 = try await Q.actorsCount(q: "", gender: "")
        XCTAssertEqual(__a25, 4, "merged_into 非空排除")
        let __a26 = try await Q.actorsCount(q: "女优丙", gender: "")
        XCTAssertEqual(__a26, 1)
        let __a27 = try await Q.actorsCount(q: "", gender: "f")
        XCTAssertEqual(__a27, 3)
        let __a28 = try await Q.actorsCount(q: "", gender: "m")
        XCTAssertEqual(__a28, 1)
    }

    // MARK: - B.20 actor

    func test_Q_actor_detailAndMovies() async throws {
        try await boot()
        let res = try await Q.actor(aid: "a1", page: 1, per: 10)
        let actor = res?["actor"] as? [String: Any]
        XCTAssertEqual(actor?["name"] as? String, "女优甲")
        XCTAssertEqual(actor?["gender"] as? Int64, 0)
        XCTAssertEqual(int64Of(res ?? [:], "total"), 3, "COUNT 同步真值（与 items 同口径）")
        XCTAssertEqual(rowsOf(res ?? [:], "items").map { $0.s("id") }, ["m12", "m01", "m03"])
        XCTAssertEqual(res?["page"] as? Int, 1)
    }

    func test_Q_actor_page2() async throws {
        try await boot()
        let res = try await Q.actor(aid: "a1", page: 2, per: 2)
        XCTAssertEqual(rowsOf(res ?? [:], "items").map { $0.s("id") }, ["m03"])
        XCTAssertEqual(int64Of(res ?? [:], "total"), 3)
    }

    func test_Q_actor_mergedIntoResolve() async throws {
        try await boot()
        let res = try await Q.actor(aid: "a5", page: 1, per: 10)
        let actor = res?["actor"] as? [String: Any]
        XCTAssertEqual(actor?["name"] as? String, "已合并女优", "actor 行保留合并号自身")
        XCTAssertEqual(int64Of(res ?? [:], "total"), 3, "影片口径解析到主号 a1")
        XCTAssertEqual(rowsOf(res ?? [:], "items").map { $0.s("id") }, ["m12", "m01", "m03"])
    }

    func test_Q_actor_taggedCountAndItems() async throws {
        try await boot()
        let res = try await Q.actor(aid: "a1", page: 1, per: 10, tagId: "t1")
        // ★ S15-07：count 与 items 同口径（tagId 非空时 JOIN movie_tags）
        XCTAssertEqual(int64Of(res ?? [:], "total"), 2)
        XCTAssertEqual(rowsOf(res ?? [:], "items").map { $0.s("id") }, ["m01", "m03"])
    }

    func test_Q_actor_missingNil() async throws {
        try await boot()
        let __a29 = try await Q.actor(aid: "nope", page: 1, per: 10)
        XCTAssertNil(__a29)
    }

    // MARK: - B.21 actorTags / B.22 actorTagCount

    func test_Q_actorTags_aggregateOrderAndPaging() async throws {
        try await boot()
        let tags = await Q.actorTags(aid: "a1")
        XCTAssertEqual(tags.count, 4)
        XCTAssertEqual(tags.first?.s("id"), "t1")
        XCTAssertEqual(tags.first?.s("name"), "巨乳")
        XCTAssertEqual(tags.first?.i("c"), 2)
        // ORDER BY c DESC, tag_id ASC（tiebreaker）
        XCTAssertEqual(tags.dropFirst().map { $0.s("id") }, ["t2", "t3", "t4"])
        // 60 上限 + 分页
        let limited = await Q.actorTags(aid: "a1", limit: 2)
        XCTAssertEqual(limited.map { $0.s("id") }, ["t1", "t2"])
        let offset = await Q.actorTags(aid: "a1", offset: 2, limit: 2)
        XCTAssertEqual(offset.map { $0.s("id") }, ["t3", "t4"])
        // merged_into → 主号聚合
        let merged = await Q.actorTags(aid: "a5")
        XCTAssertEqual(merged.count, 4)
    }

    func test_Q_actorTagCount_distinct() async throws {
        try await boot()
        let __a30 = try await Q.actorTagCount(aid: "a1")
        XCTAssertEqual(__a30, 4)
        let __a31 = try await Q.actorTagCount(aid: "a5")
        XCTAssertEqual(__a31, 4, "merged_into 解析到主号")
        let __a32 = try await Q.actorTagCount(aid: "a2")
        XCTAssertEqual(__a32, 2, "a2 出演 m01（t1/t2）与 m07（无标签）→ DISTINCT 2")
    }

    // MARK: - B.23 shtCategories

    func test_Q_shtCategories_segments() async throws {
        try await boot()
        let res = try await Q.shtCategories()
        let cats = rowsOf(res, "categories")
        XCTAssertEqual(cats.count, 4)
        XCTAssertEqual(cats.first?.s("name"), "有码原创")
        XCTAssertEqual(cats.first?.i("c"), 3)
        let subs = rowsOf(res, "subs")
        let subMap = Dictionary(subs.map { ($0.s("main"), $0.i("c")) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(subMap, ["tc": 3, "tw": 1, "eu": 1], "board NULL 的帖子不入 subs")
        let mains = res["mains"] as? [[String: Any]] ?? []
        XCTAssertEqual(mains.count, 3)
        XCTAssertEqual(mains.first?["name"] as? String, "tc", "Kotlin 侧按 c 降序")
        XCTAssertEqual(mains.first?["c"] as? Int64, 3)
        let types = rowsOf(res, "types")
        let typeMap = Dictionary(types.map { ($0.s("sub") + "|" + $0.s("name"), $0.i("c")) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(typeMap["亚洲无码原创|磁力链接"], 2)
        XCTAssertEqual(typeMap["亚洲无码原创|字幕"], 1)
        XCTAssertEqual(typeMap["台湾论坛|图片区"], 1)
        XCTAssertEqual(res["approx"] as? Bool, true)
        let total = int64Of(res, "total")
        XCTAssertGreaterThanOrEqual(total, 6, "information_schema 估算（异常才 -1）")
        XCTAssertNotEqual(total, -1)
    }

    // MARK: - B.26 shtBrowse

    func test_Q_shtBrowse_defaultList() async throws {
        try await boot()
        let res = try await Q.shtBrowse()
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("tid") }, ["1001", "1002", "1003", "1004", "1005", "1006"], "post_date DESC, tid DESC")
        XCTAssertEqual(int64Of(res, "total"), -1)
        XCTAssertEqual(res["approx"] as? Bool, true)
        XCTAssertEqual(res["derived"] as? String, "")
        XCTAssertEqual(res["page"] as? Int, 1)
        XCTAssertEqual(items.first?.s("title"), "Tokyo Hot Collection")
        XCTAssertFalse(items.first?.s("last_checked").isEmpty ?? true, "★ S12-P5 锚点列 last_checked 必须在 SELECT")
        XCTAssertEqual(items.first?.s("author"), "userA")
    }

    func test_Q_shtBrowse_tidDirect() async throws {
        try await boot()
        let res = try await Q.shtBrowse(q: "1002")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("tid") }, ["1002"])
        XCTAssertTrue((res["covers"] as? [String: String] ?? [:]).isEmpty, "1002 无图 → covers 空")
        XCTAssertEqual(res["derived"] as? String, "")
    }

    func test_Q_shtBrowse_ftsMultiWord() async throws {
        try await boot()
        let res = try await Q.shtBrowse(q: "Tokyo")
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("tid") }, ["1001"], "MATCH(title) AGAINST NL 模式")
    }

    func test_Q_shtBrowse_singleCharDerived() async throws {
        try await boot()
        let res = try await Q.shtBrowse(q: "字")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("tid") }, ["1005"], "单字 FTS 切不出 → 派生表内 LIKE（title/type）")
        XCTAssertEqual(res["derived"] as? String, "已限定最近 5000 帖内匹配")
    }

    func test_Q_shtBrowse_filters() async throws {
        try await boot()
        let main = try await Q.shtBrowse(main: "tc")
        XCTAssertEqual(rowsOf(main, "items").map { $0.s("tid") }, ["1001", "1002", "1005"])
        let nullBoard = try await Q.shtBrowse(main: "国产原创")
        // (board = ? OR (board IS NULL AND cat_name = ?)) → board NULL 回落 cat_name
        XCTAssertEqual(rowsOf(nullBoard, "items").map { $0.s("tid") }, ["1003"])
        let cat = try await Q.shtBrowse(cat: "国产原创")
        XCTAssertEqual(rowsOf(cat, "items").map { $0.s("tid") }, ["1003"])
        let type = try await Q.shtBrowse(type: "字幕")
        XCTAssertEqual(rowsOf(type, "items").map { $0.s("tid") }, ["1005"])
        let magnet = try await Q.shtBrowse(hasMagnet: true)
        XCTAssertEqual(rowsOf(magnet, "items").map { $0.s("tid") }, ["1001", "1002", "1003", "1006"])
        let none = try await Q.shtBrowse(main: "tc", type: "图片区")
        XCTAssertTrue(rowsOf(none, "items").isEmpty, "组合无命中 → 空页")
    }

    func test_Q_shtBrowse_updatedSortDerived() async throws {
        try await boot()
        let res = try await Q.shtBrowse(sort: "updated")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.first?.s("tid"), "1006", "last_checked DESC → 1006（2025-07-01）")
        XCTAssertEqual(res["derived"] as? String, "已限定最近 20000 帖内排序 (按更新时间)")
    }

    func test_Q_shtBrowse_keysetAnchor() async throws {
        try await boot()
        let p1 = try await Q.shtBrowse(page: 1, per: 2)
        let items1 = rowsOf(p1, "items")
        XCTAssertEqual(items1.map { $0.s("tid") }, ["1001", "1002"])
        let anchor = (items1.last?.s("post_date") ?? "", items1.last?.s("tid") ?? "")
        let p2 = try await Q.shtBrowse(page: 2, per: 2, anchor: anchor)
        XCTAssertEqual(rowsOf(p2, "items").map { $0.s("tid") }, ["1003", "1004"], "keyset: post_date/tid 双键续页")
    }

    func test_Q_shtBrowse_coversMap() async throws {
        try await boot()
        let res = try await Q.shtBrowse()
        let covers = res["covers"] as? [String: String] ?? [:]
        XCTAssertEqual(covers["1001"], "https://img/s1a.jpg", "MIN(url) 聚合")
        XCTAssertEqual(covers["1003"], "https://img/s3a.jpg")
        XCTAssertEqual(covers["1004"], "https://img/s4a.jpg")
        XCTAssertNil(covers["1002"])
    }

    // MARK: - B.27 shtBrowseCount

    func test_Q_shtBrowseCount_modes() async throws {
        try await boot()
        let __a33 = try await Q.shtBrowseCount(main: "tc", cat: "", type: "", q: "", hasMagnet: false, sort: "date")
        XCTAssertEqual(__a33, 3)
        let __a34 = try await Q.shtBrowseCount(main: "", cat: "", type: "", q: "", hasMagnet: true, sort: "date")
        XCTAssertEqual(__a34, 4)
        let __a35 = try await Q.shtBrowseCount(main: "", cat: "", type: "", q: "Tokyo", hasMagnet: false, sort: "date")
        XCTAssertEqual(__a35, 1)
        let __a36 = try await Q.shtBrowseCount(main: "", cat: "", type: "", q: "字", hasMagnet: false, sort: "date")
        XCTAssertEqual(__a36, 1, "单字 LIKE 计数")
        let __a37 = try await Q.shtBrowseCount(main: "", cat: "", type: "", q: "", hasMagnet: false, sort: "updated")
        XCTAssertEqual(__a37, 6, "updated → 派生窗口计数（窗口 ⊇ 全表）")
        let __a38 = try await Q.shtBrowseCount(main: "", cat: "", type: "", q: "", hasMagnet: false, sort: "date")
        XCTAssertEqual(__a38, 6, "date → 全库真值")
    }

    // MARK: - B.28 shtThread

    func test_Q_shtThread_fullBuckets() async throws {
        try await boot()
        let t = try await Q.shtThread(tid: "1001")
        XCTAssertEqual(t?["tid"] as? Int64, 1001)
        XCTAssertEqual(t?["title"] as? String, "Tokyo Hot Collection")
        XCTAssertEqual(t?["author"] as? String, "userA")
        // magnets：link 空 → 补 magnet:?xt=urn:btih:hash；已有 link 原样
        let magnets = t?["magnets"] as? [[String: Any]] ?? []
        XCTAssertEqual(magnets.count, 2)
        XCTAssertEqual(magnets.first?["hash"] as? String, "hashs1a")
        XCTAssertEqual(magnets.first?["link"] as? String, "magnet:?xt=urn:btih:hashs1a")
        XCTAssertEqual(magnets.last?["link"] as? String, "magnet:?xt=urn:btih:hashs1b&dn=x")
        XCTAssertNotNil(t?["ed2k"], "ed2k 键存在")
        XCTAssertEqual((t?["ed2k"] as? [Row])?.count, 1)
        XCTAssertEqual((t?["ed2k"] as? [Row])?.first?.s("url"), "ed2k://|file|coll.mp4|1468006400|ABCD|")
        XCTAssertEqual(t?["images"] as? [String], ["https://img/s1a.jpg", "https://img/s1b.jpg"])
        XCTAssertEqual(t?["videos"] as? [String], ["https://vid/v1.mp4"])
        XCTAssertEqual(t?["words"] as? Int64, 500, "words = article_words")
        // 正文 blocks：JSONArray 解析（t/i 字符串键，sz 整型键缺省 0）
        let blocks = t?["blocks"] as? [[String: Any]] ?? []
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?["t"] as? String, "第一段正文")
        XCTAssertEqual(blocks.first?["sz"] as? Int, 0)
        XCTAssertEqual(blocks.last?["i"] as? String, "https://img/x1.jpg")
        XCTAssertEqual(blocks.last?["sz"] as? Int, 120)
    }

    func test_Q_shtThread_plainArticleNoBlocks() async throws {
        try await boot()
        let t = try await Q.shtThread(tid: "1002")
        XCTAssertNil(t?["blocks"], "非 JSON 正文 → 无 blocks 键")
        XCTAssertEqual(t?["words"] as? Int64, 300)
        XCTAssertEqual((t?["magnets"] as? [[String: Any]])?.count, 1)
    }

    func test_Q_shtThread_missingNil() async throws {
        try await boot()
        let __v = try await Q.shtThread(tid: "9999")
        XCTAssertNil(__v)
    }

    // MARK: - B.29 shtExport

    func test_Q_shtExport_allKinds() async throws {
        try await boot()
        var collected: [Row] = []
        try await Q.shtExport(main: "tc", cat: "", type: "", dFrom: "", dTo: "") { rows in
            collected.append(contentsOf: rows)
        }
        XCTAssertEqual(collected.count, 5, "tc 3 帖：磁力 3 + ED2K 1 + 视频 1")
        let byKind = Dictionary(grouping: collected) { $0.s("kind") }
        XCTAssertEqual(byKind["磁力"]?.count, 3)
        XCTAssertEqual(byKind["ED2K"]?.count, 1)
        XCTAssertEqual(byKind["视频"]?.count, 1)
        XCTAssertEqual(collected.first?.s("tid"), "1001", "post_date DESC 首帖")
        XCTAssertEqual(collected.first?.s("title"), "Tokyo Hot Collection")
        XCTAssertEqual(collected.first?.s("kind"), "磁力")
        XCTAssertTrue(collected.first?.s("link").hasPrefix("magnet:?xt=urn:btih:") ?? false)
        let ed2k = byKind["ED2K"]?.first
        XCTAssertEqual(ed2k?.s("link"), "ed2k://|file|coll.mp4|1468006400|ABCD|")
        XCTAssertEqual(ed2k?.s("size"), "1.40 GiB")
    }

    func test_Q_shtExport_queryCapAndEmpty() async throws {
        try await boot()
        // 标题词 FTS（≥2 字）
        var byQuery: [Row] = []
        try await Q.shtExport(main: "", cat: "", type: "", dFrom: "", dTo: "", q: "Tokyo") { rows in
            byQuery.append(contentsOf: rows)
        }
        XCTAssertEqual(byQuery.count, 4, "q 命中 1001 → 2 磁力 + 1 ED2K + 1 视频")
        // maxThreads 封顶：只处理第一帖
        var capped: [Row] = []
        try await Q.shtExport(main: "tc", cat: "", type: "", dFrom: "", dTo: "", maxThreads: 1) { rows in
            capped.append(contentsOf: rows)
        }
        XCTAssertEqual(capped.count, 4)
        // 日期区间
        var ranged: [Row] = []
        try await Q.shtExport(main: "", cat: "", type: "", dFrom: "2025-05-01", dTo: "2025-05-31 23:59:59") { rows in
            ranged.append(contentsOf: rows)
        }
        XCTAssertEqual(ranged.count, 2)
        XCTAssertTrue(ranged.allSatisfy { $0.s("kind") == "磁力" })
        // 无命中分类 → 空回调
        var empty: [Row] = []
        try await Q.shtExport(main: "", cat: "台湾论坛", type: "", dFrom: "", dTo: "") { rows in
            empty.append(contentsOf: rows)
        }
        XCTAssertTrue(empty.isEmpty, "1004 无磁力/ed2k/视频")
    }

    // MARK: - B.25 shtSemantic

    func test_Q_shtSemantic_nilWithoutModel() async throws {
        try await boot()
        let res = await Q.shtSemantic(q: "Tokyo")
        XCTAssertNil(res, "模型未导入 → null（禁止静默降级）")
    }

    // MARK: - B.30 articles

    func test_Q_articles_listOrderAndCount() async throws {
        try await boot()
        let res = try await Q.articles(page: 1, per: 10)
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("id") }, ["art1", "art2", "art3"], "released_at DESC")
        XCTAssertEqual(int64Of(res, "total"), 3, "COUNT 同步真值")
        XCTAssertEqual(res["page"] as? Int, 1)
        XCTAssertEqual(res["per"] as? Int, 10)
        XCTAssertEqual(items.first?.s("category_name"), "业界动态")
        XCTAssertEqual(items.first?.i("word_count"), 100)
    }

    func test_Q_articles_pagination() async throws {
        try await boot()
        let res = try await Q.articles(page: 2, per: 2)
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("id") }, ["art3"])
        XCTAssertEqual(int64Of(res, "total"), 3)
        XCTAssertEqual(res["page"] as? Int, 2)
    }

    func test_Q_articles_categoryAndKeyword() async throws {
        try await boot()
        let cat = try await Q.articles(page: 1, per: 10, categoryId: 1)
        XCTAssertEqual(rowsOf(cat, "items").map { $0.s("id") }, ["art1", "art2"])
        XCTAssertEqual(int64Of(cat, "total"), 2)
        // %kw% 双侧通配（正文列 content_text）
        let kw1 = try await Q.articles(page: 1, per: 10, q: "abp-001")
        XCTAssertEqual(rowsOf(kw1, "items").map { $0.s("id") }, ["art1"])
        XCTAssertEqual(int64Of(kw1, "total"), 1)
        // 标题命中
        let kw2 = try await Q.articles(page: 1, per: 10, q: "资讯")
        XCTAssertEqual(rowsOf(kw2, "items").map { $0.s("id") }, ["art1", "art2"])
        XCTAssertEqual(int64Of(kw2, "total"), 2)
    }

    // MARK: - B.31 article

    func test_Q_article_detail() async throws {
        try await boot()
        let row = try await Q.article(aid: "art1")
        XCTAssertEqual(row?.s("title"), "资讯标题 Alpha")
        XCTAssertEqual(row?.s("origin_name"), "来源一")
        XCTAssertEqual(row?.s("category_name"), "业界动态")
        XCTAssertTrue(row?.s("content_html").contains("abp-001") ?? false, "content_html 原版排版正文")
        XCTAssertEqual(row?.i("word_count"), 100)
        let __v = try await Q.article(aid: "nope")
        XCTAssertNil(__v)
    }

    // MARK: - B.32 articleMovies / B.35 movieArticles

    func test_Q_articleMovies_positionOrder() async throws {
        try await boot()
        let rows = await Q.articleMovies(aid: "art1")
        XCTAssertEqual(rows.map { $0.s("movie_id") }, ["m01", "m03"], "ORDER BY am.position")
        XCTAssertEqual(rows.first?.s("number"), "abp-001")
        XCTAssertEqual(rows.first?.s("thumb_url"), "https://img/t1.jpg")
        let __v = try await Q.articleMovies(aid: "nope").isEmpty
        XCTAssertTrue(__v)
    }

    func test_Q_movieArticles_ofMovie() async throws {
        try await boot()
        let rows = await Q.movieArticles(mid: "m03")
        XCTAssertEqual(rows.map { $0.s("id") }, ["art1", "art3"], "released_at DESC")
        XCTAssertEqual(rows.first?.s("category_name"), "业界动态")
        let single = await Q.movieArticles(mid: "m01")
        XCTAssertEqual(single.map { $0.s("id") }, ["art1"])
        let __v = try await Q.movieArticles(mid: "m06").isEmpty
        XCTAssertTrue(__v)
    }

    // MARK: - B.33 articleCategories

    func test_Q_articleCategories_grouped() async throws {
        try await boot()
        let rows = await Q.articleCategories()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.i("category_id"), 1)
        XCTAssertEqual(rows.first?.s("category_name"), "业界动态")
        XCTAssertEqual(rows.first?.i("n"), 2, "ORDER BY n DESC")
        XCTAssertEqual(rows.last?.s("category_name"), "作品评测")
    }

    // MARK: - B.34 hotReviewKeys / B.36 hotReviews

    func test_Q_hotReviewKeys_periods() async throws {
        try await boot()
        let __a39 = try await Q.hotReviewKeys(period: "day")
        XCTAssertEqual(__a39, ["2025-06-01", "2025-05-31"], "period_key DESC")
        let __a40 = try await Q.hotReviewKeys(period: "week")
        XCTAssertEqual(__a40, ["2025-W23"])
        let __a41 = try await Q.hotReviewKeys(period: "month").isEmpty
        XCTAssertTrue(__a41, "无数据周期 → 空列表")
    }

    func test_Q_hotReviews_rankOrder() async throws {
        try await boot()
        let res = try await Q.hotReviews(period: "day")
        XCTAssertEqual(res["hasData"] as? Bool, true)
        XCTAssertEqual(res["key"] as? String, "2025-06-01", "默认取最新批次")
        XCTAssertEqual(res["period"] as? String, "day")
        XCTAssertEqual(int64Of(res, "total"), 3, "COUNT 同步真值")
        let items = rowsOf(res, "items")
        XCTAssertEqual(items.map { $0.s("movie_id") }, ["m03", "m01", "m12"], "`rank` 升序（反引号）")
        XCTAssertEqual(items.first?.i("rank"), 1)
        XCTAssertEqual(items.first?.i("likes_count"), 120)
        XCTAssertEqual(items.first?.s("user_name"), "userA")
        XCTAssertEqual((res["keys"] as? [String])?.count, 2)
    }

    func test_Q_hotReviews_explicitKeyAndPage() async throws {
        try await boot()
        let res = try await Q.hotReviews(period: "day", periodKey: "2025-05-31")
        XCTAssertEqual(res["key"] as? String, "2025-05-31")
        XCTAssertEqual(int64Of(res, "total"), 2)
        XCTAssertEqual(rowsOf(res, "items").map { $0.s("movie_id") }, ["m07", "m05"])
        let p2 = try await Q.hotReviews(period: "day", page: 2, per: 2)
        XCTAssertEqual(rowsOf(p2, "items").map { $0.s("movie_id") }, ["m12"])
        XCTAssertEqual(int64Of(p2, "total"), 3)
        XCTAssertEqual(p2["per"] as? Int, 2)
    }

    func test_Q_hotReviews_noDataEmptyState() async throws {
        try await boot()
        let res = try await Q.hotReviews(period: "month")
        // ★ P7：keys 为空不再抛异常 → hasData=false 空态
        XCTAssertEqual(res["hasData"] as? Bool, false)
        XCTAssertEqual(int64Of(res, "total"), 0)
        XCTAssertEqual(res["key"] as? String, "")
        XCTAssertEqual(res["keys"] as? [String], [])
        XCTAssertTrue(rowsOf(res, "items").isEmpty)
    }

    // MARK: - B.3 taxonomy / B.15 filters / B.2 标签索引

    func test_Q_taxonomy_segments() async throws {
        try await boot()
        let res = await Q.taxonomy()
        let makers = rowsOf(res, "makers")
        XCTAssertEqual(makers.first?.s("id"), "mk1")
        XCTAssertEqual(makers.first?.s("name"), "片商一")
        XCTAssertEqual(makers.first?.i("c"), 5)
        let codes = rowsOf(res, "codes")
        XCTAssertEqual(codes.first?.s("id"), "c1")
        XCTAssertEqual(codes.first?.s("name"), "abp")
        XCTAssertEqual(codes.first?.i("c"), 6)
        let tags = rowsOf(res, "tags")
        XCTAssertEqual(tags.count, 4)
        XCTAssertEqual(tags.first?.s("id"), "t1")
        XCTAssertEqual(tags.first?.s("name"), "巨乳")
        XCTAssertEqual(tags.first?.i("c"), 2)
        let years = rowsOf(res, "years")
        XCTAssertEqual(years.count, 4)
        // jdb.filters.years：ORDER BY year DESC（非 c DESC）→ 2025（m05/m12）首位
        XCTAssertEqual(years.first?.i("year"), 2025)
        XCTAssertEqual(years.first?.i("c"), 2)
        XCTAssertEqual(res["fallback"] as? Bool, false, "makers/codes 索引表非空 → 无回退")
        XCTAssertNotNil(res["ts"])
    }

    func test_Q_taxonomy_tagIndexResolution() async throws {
        try await boot()
        _ = await Q.taxonomy()   // rememberRemoteTags → 标签索引可用
        XCTAssertEqual(Q.tagIdByName("巨乳"), "t1")
        XCTAssertEqual(Q.tagIdByName("單體作品"), "t3")
        XCTAssertNil(Q.tagIdByName("不存在的标签xx"))
        XCTAssertEqual(Q.tagNameOf("t4"), "制服")
        XCTAssertNil(Q.tagNameOf("t999"))
        XCTAssertEqual(JdbSearch.tagId(t: "123"), "123", "纯数字 tag_id 原样返回")
    }

    func test_Q_filters_segments() async throws {
        try await boot()
        let res = await Q.filters()
        let years = rowsOf(res, "years")
        XCTAssertEqual(years.count, 4)
        // 同 taxonomy：ORDER BY year DESC → 2025 首位
        XCTAssertEqual(years.first?.i("year"), 2025)
        let letters = rowsOf(res, "letters")
        XCTAssertEqual(letters.count, 5)
        XCTAssertEqual(letters.first?.s("letter"), "abp")
        XCTAssertEqual(letters.first?.i("c"), 6)
        let makers = rowsOf(res, "makers")
        XCTAssertEqual(makers.count, 3, "NULL maker 排除")
        XCTAssertEqual(makers.first?.s("id"), "mk1")
        XCTAssertEqual(makers.first?.i("c"), 5)
        XCTAssertEqual(res["months"] as? [Int], Array(1...12), "months 由 Kotlin 侧生成")
        // 无 assets 标签数据源 → 分类/拍平标签均空
        XCTAssertEqual((res["categories"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((res["tags"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - 稀疏库：taxonomy 回退 + articles 缺表（B.3 已知问题逐字复刻）

    func test_Q_taxonomy_fallbackAndArticlesMissingOnSparseDb() async throws {
        try await boot()
        let alt = MySQLPoolSettings(
            host: Self.host, port: Self.port, user: Self.user, pass: Self.pass,
            jdbDb: Self.altDbName, shtDb: Self.dbName, tls: false,
            connectTimeout: 5, queryTimeout: 8)
        Db.configure(settingsProvider: { alt }, hasNetwork: { true })
        Db.reset()
        defer {
            let main = MySQLPoolSettings(
                host: Self.host, port: Self.port, user: Self.user, pass: Self.pass,
                jdbDb: Self.dbName, shtDb: Self.dbName, tls: false,
                connectTimeout: 5, queryTimeout: 8)
            Db.configure(settingsProvider: { main }, hasNetwork: { true })
            Db.reset()
        }
        // makers 索引表缺失 → 回退 movies 聚合；codes 回退 SQL 无 SqlPolicy 模板 → 被拒恒空
        let tax = await Q.taxonomy()
        XCTAssertEqual(tax["fallback"] as? Bool, true)
        let makers = rowsOf(tax, "makers")
        XCTAssertEqual(makers.first?.s("id"), "mk1")
        XCTAssertEqual(makers.first?.i("c"), 5)
        XCTAssertEqual(rowsOf(tax, "codes").count, 0, "回退 codes 被 SqlPolicy 拒绝 → q() 吞掉 → 恒空（Android 已知问题）")
        XCTAssertEqual(rowsOf(tax, "years").count, 4)
        XCTAssertEqual(rowsOf(tax, "tags").count, 4)
        // articles 表缺失 → 明确文案（不静默返回空）
        do {
            _ = try await Q.articles(page: 1, per: 10)
            XCTFail("expected QRuntimeError")
        } catch let e as QRuntimeError {
            XCTAssertTrue(e.message.contains("articles"), e.message)
        }
    }
}
