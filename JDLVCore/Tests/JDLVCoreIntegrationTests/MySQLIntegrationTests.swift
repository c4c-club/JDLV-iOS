import XCTest
import MySQLNIO
@testable import JDLVCore

// P3 集成测试：真实 MySQL 8（CI: services mysql:8.0 / 本地: Docker mysql 容器）。
// 由 core-mysql job 运行（env 提供连接参数）；core-linux job 用 --skip 排除本 target。
// 注意：被测库是测试自建 fixture 库，DDL/DML 仅用于测试，生产远程库仍只读。

final class MySQLIntegrationTests: XCTestCase {

    static let host = ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_HOST"] ?? "127.0.0.1"
    static let port = Int(ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_PORT"] ?? "3306")!
    static let user = ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_USER"] ?? "root"
    static let pass = ProcessInfo.processInfo.environment["JDLV_TEST_MYSQL_PASS"].flatMap { $0.isEmpty ? nil : $0 }   // R4：空/未设 = nil（不发口令；MySQL8 空口令账号语义）
    static let dbName = "jdlv_it"

    static var group: EventLoopGroup?
    static var bootConn: MySQLConnection!

    override class func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override class func tearDown() {
        if let c = bootConn, !c.isClosed {
            _ = try? c.close().wait()
        }
        bootConn = nil
        // 不 syncShutdownGracefully：强关在途命令 channel 会触发 MySQLNIO 断言
        super.tearDown()
    }

    /// 装载 fixture（逐条语句，不用多语句）
    func bootstrapFixture() async throws {
        if MySQLIntegrationTests.bootConn == nil || MySQLIntegrationTests.bootConn.isClosed {
            let addr = try SocketAddress.makeAddressResolvingHost(
                Self.host, port: Self.port)
            MySQLIntegrationTests.bootConn = try await awaitFuture(
                MySQLConnection.connect(
                    to: addr, username: Self.user, database: "",
                    password: Self.pass, tlsConfiguration: nil, serverHostname: nil,
                    on: Self.group!.next()))
        }
        let conn = MySQLIntegrationTests.bootConn!
        _ = try await awaitFuture(conn.simpleQuery("DROP DATABASE IF EXISTS \(Self.dbName)"))
        _ = try await awaitFuture(conn.simpleQuery("CREATE DATABASE \(Self.dbName) CHARACTER SET utf8mb4"))
        _ = try await awaitFuture(conn.simpleQuery("USE \(Self.dbName)"))
        for stmt in Self.schemaStatements() {
            _ = try await awaitFuture(conn.simpleQuery(stmt))
        }
        for stmt in Self.seedStatements() {
            _ = try await awaitFuture(conn.simpleQuery(stmt))
        }
    }

    /// 每个测试独立池 + 独立 fixture；teardown 全清
    var pool: MySQLPool!

    override func setUpWithError() throws {
        OfflineGate.reset(now: 0)
        // 基建测试的任意 SQL 不在 106 生产模板内 → 关闭 enforce（Q 层测试保持 enforce=true）
        SqlPolicy.setEnforceForTesting(false)
        pool = MySQLPool()
    }

    override func tearDownWithError() throws {
        OfflineGate.reset(now: 0)
        SqlPolicy.setEnforceForTesting(true)
        pool = nil
    }

    func makePoolSettings(host: String? = nil, port: Int? = nil, tls: Bool = false,
                          connectTimeout: Int = 5) -> MySQLPoolSettings {
        MySQLPoolSettings(
            host: host ?? Self.host, port: port ?? Self.port,
            user: Self.user, pass: Self.pass ?? "",   // String? → pool 设置非可选；空串由 pool 转 nil 连接
            jdbDb: Self.dbName, shtDb: Self.dbName,
            tls: tls, connectTimeout: connectTimeout, queryTimeout: 8)
    }

    func installPool(_ s: MySQLPoolSettings) {
        pool.settingsProvider = { s }
        pool.hasNetwork = { true }
    }

    // MARK: fixture schema/seed

    static func schemaStatements() -> [String] {
        [
            "CREATE TABLE movies (id VARCHAR(32) PRIMARY KEY, number VARCHAR(64), " +
                "title VARCHAR(255), release_date VARCHAR(20), year INT, score DECIMAL(4,1), " +
                "want_watch_count INT, magnets_count INT, number_letter VARCHAR(8), " +
                "cover_url TEXT, has_cnsub TINYINT, can_play TINYINT, maker_id VARCHAR(32), " +
                "maker_name VARCHAR(128), series_id VARCHAR(32), director_id VARCHAR(32), " +
                "publisher_id VARCHAR(32))",
            "CREATE TABLE movie_tags (movie_id VARCHAR(32), tag_id VARCHAR(32), " +
                "tag_name VARCHAR(128), PRIMARY KEY(movie_id, tag_id))",
            "CREATE TABLE movie_actors (movie_id VARCHAR(32), actor_id VARCHAR(32), " +
                "actor_name VARCHAR(190), PRIMARY KEY(movie_id, actor_id))",
            "CREATE TABLE actors (id VARCHAR(32) PRIMARY KEY, name VARCHAR(190), " +
                "gender INT, merged_into VARCHAR(32))",
            "CREATE TABLE flags (id INT PRIMARY KEY, b BIT, dt DATETIME, blob_col BLOB)",
            "CREATE TABLE missing_but_queried_nothing (id INT)",
        ]
    }

    static func seedStatements() -> [String] {
        [
            "INSERT INTO movies VALUES ('m01','abc-001','演示影片 001','2024-01-15',2024,8.5,120,3,'abc','https://x/c.jpg',1,0,'mk1','片商一','sr1','dr1','pb1')",
            "INSERT INTO movies VALUES ('m02','abc-002','Demo Two 002','2024-02-20',2024,7.2,45,0,'abc',NULL,0,1,'mk1','片商一',NULL,NULL,NULL)",
            "INSERT INTO movies VALUES ('m03','xyz-003','演示影片 003','2023-12-31',2023,9.1,900,7,'xyz','https://x/z.jpg',1,1,'mk2','片商二','sr2','dr1','pb2')",
            "INSERT INTO movies VALUES ('m04',NULL,'无番号影片',NULL,2022,NULL,0,0,NULL,NULL,0,0,NULL,NULL,NULL,NULL,NULL)",
            "INSERT INTO movie_tags VALUES ('m01','t1','巨乳'),('m01','t2','人妻'),('m03','t1','巨乳'),('m03','t3','單體作品')",
            "INSERT INTO movie_actors VALUES ('m01','a1','女优甲'),('m03','a1','女优甲'),('m03','a2','女优乙')",
            "INSERT INTO actors VALUES ('a1','女优甲',0,NULL),('a2','女优乙',1,NULL)",
            "INSERT INTO flags VALUES (1,b'1','2024-06-01 12:30:00',_binary 0x89504E470D0A1A0A)",
        ]
    }

    // MARK: 连接 / 基础查询

    func test_01_connectAndSelectOne() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(which: "jdb", sql: "SELECT 1")
        XCTAssertEqual(rows.count, 1)
    }

    func test_02_parameterizedQuery() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb",
            sql: "SELECT id FROM movies WHERE number_letter = ? ORDER BY id",
            params: [.string("abc")])
        XCTAssertEqual(rows.map { $0.s("id") }, ["m01", "m02"])
    }

    func test_03_chineseRoundtrip() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb", sql: "SELECT title FROM movies WHERE id = ?", params: [.string("m01")])
        XCTAssertEqual(rows.first?.s("title"), "演示影片 001")
    }

    func test_04_nullHandling() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb",
            sql: "SELECT release_date, number, score FROM movies WHERE id = ?",
            params: [.string("m04")])
        let r = try XCTUnwrap(rows.first)
        XCTAssertTrue(r.isNull("release_date"))
        XCTAssertTrue(r.isNull("number"))
        XCTAssertTrue(r.isNull("score"))
        XCTAssertEqual(r.s("release_date"), "")
        XCTAssertEqual(r.i("score"), 0)
    }

    func test_05_decimalToDouble() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb", sql: "SELECT score FROM movies WHERE id = ?", params: [.string("m01")])
        XCTAssertEqual(rows.first?.d("score") ?? 0, 8.5, accuracy: 0.001)
    }

    func test_06_blobRoundtrip() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb", sql: "SELECT blob_col FROM flags WHERE id = 1")
        // BLOB → UTF-8 String（norm 语义）；魔数 PNG 头不是合法 UTF-8 → 容忍替换/原样
        let v = rows.first?.s("blob_col") ?? ""
        XCTAssertFalse(v.isEmpty || rows.first == nil)
    }

    func test_07_datetimeToString() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(which: "jdb", sql: "SELECT dt FROM flags WHERE id = 1")
        let s = rows.first?.s("dt") ?? ""
        XCTAssertTrue(s.hasPrefix("2024-06-01 12:30:00"), "dt=\(s)")
    }

    func test_08_bitToBool() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(which: "jdb", sql: "SELECT b FROM flags WHERE id = 1")
        XCTAssertEqual(rows.first?.b("b"), true)
    }

    func test_09_intColumns() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb",
            sql: "SELECT want_watch_count, magnets_count FROM movies WHERE id = ?",
            params: [.string("m03")])
        XCTAssertEqual(rows.first?.i("want_watch_count"), 900)
        XCTAssertEqual(rows.first?.i("magnets_count"), 7)
    }

    func test_10_orderAndLimitParams() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb",
            sql: "SELECT id FROM movies WHERE release_date IS NOT NULL ORDER BY release_date DESC LIMIT ?",
            params: [.int(2)])
        XCTAssertEqual(rows.map { $0.s("id") }, ["m02", "m01"])
    }

    func test_11_largeInList() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        var ids = ["'m01'", "'m02'", "'m03'"]
        ids += (0..<497).map { String(format: "'x%03d'", $0) }
        let rows = try await pool.query(
            which: "jdb", sql: "SELECT id FROM movies WHERE id IN (\(ids.joined(separator: ",")))")
        XCTAssertEqual(rows.count, 3)
    }

    // MARK: 超时 / 取消 / 重连 / ping

    func test_12_statementTimeoutSelectSleep() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        do {
            _ = try await pool.query(
                which: "jdb", sql: "SELECT SLEEP(5)", timeoutSec: 1)
            XCTFail("expected timeout")
        } catch let e as QueryTimeoutError {
            XCTAssertTrue(e.message.contains("查询超时"), e.message)
        }
        // 池仍可用（作废旧连接，新查询走新连接）
        let rows = try await pool.query(which: "jdb", sql: "SELECT 1")
        XCTAssertEqual(rows.count, 1)
    }

    func test_13_cancelAbortsAndInvalidates() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let task = Task {
            try await pool.query(which: "jdb", sql: "SELECT SLEEP(5)", timeoutSec: 30)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // 预期
        }
        // 池仍可用
        let rows = try await pool.query(which: "jdb", sql: "SELECT 1")
        XCTAssertEqual(rows.count, 1)
    }

    func test_14_reconnectAfterServerKill() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        _ = try await pool.query(which: "jdb", sql: "SELECT 1")   // 建立一条池内连接
        // 用管理连接杀掉 jdlv_it 里的业务连接
        let addr = try SocketAddress.makeAddressResolvingHost(Self.host, port: Self.port)
        let killer = try await awaitFuture(
            MySQLConnection.connect(
                to: addr, username: Self.user, database: "",
                password: Self.pass, tlsConfiguration: nil, serverHostname: nil,
                on: Self.group!.next()))
        // 只杀空闲（Sleep）连接：在途 SLEEP 连接被杀会触发 MySQLNIO 命令未收尾断言
        let procs = try await awaitFuture(
            killer.query(
                "SELECT id FROM information_schema.processlist " +
                    "WHERE db = ? AND command = 'Sleep' AND id != CONNECTION_ID()",
                [MySQLData(string: Self.dbName)]))
        for p in procs {
            if let pid = p.column("id")?.int {
                _ = try? await awaitFuture(killer.query("KILL \(pid)"))
            }
        }
        _ = try? await awaitFuture(killer.close())
        // 池自动重建连接
        let rows = try await pool.query(which: "jdb", sql: "SELECT 1")
        XCTAssertEqual(rows.count, 1)
    }

    func test_15_pingTrueAndClearsOffline() async throws {
        try await bootstrapFixture()
        OfflineGate.mark("jdb", ttlMs: 60_000)
        installPool(makePoolSettings())
        let ok = await pool.ping("jdb")
        XCTAssertTrue(ok)
        XCTAssertFalse(OfflineGate.isOffline("jdb"))
    }

    func test_16_pingBadHostFalse() async {
        installPool(makePoolSettings(host: "127.0.0.1", port: 1))
        let ok = await pool.ping("jdb")
        XCTAssertFalse(ok)
    }

    func test_17_resetAllInvalidatesGeneration() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        _ = try await pool.query(which: "jdb", sql: "SELECT 1")
        pool.resetAll()
        OfflineGate.reset(now: 0)
        let rows = try await pool.query(which: "jdb", sql: "SELECT 1")
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: 离线标记 / 错误分类

    func test_18_connRefusedMarksOffline60s() async throws {
        installPool(makePoolSettings(host: "127.0.0.1", port: 1))
        do {
            _ = try await pool.query(which: "jdb", sql: "SELECT 1")
            XCTFail("expected failure")
        } catch {
            // 预期连接失败
        }
        XCTAssertTrue(OfflineGate.isOffline("jdb"))
        XCTAssertFalse(OfflineGate.isOffline("sht"))
    }

    func test_19_noNetworkFastFail() async throws {
        installPool(makePoolSettings())
        pool.hasNetwork = { false }
        do {
            _ = try await pool.query(which: "jdb", sql: "SELECT 1")
            XCTFail("expected NoNetworkError")
        } catch let e as NoNetworkError {
            XCTAssertTrue(e.message.contains("无网络"))
        }
        XCTAssertTrue(OfflineGate.isOffline("jdb"))
    }

    func test_20_semanticErrorNoRetryNoOffline() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        do {
            _ = try await pool.query(which: "jdb", sql: "SELECT * FROM no_such_table_xx")
            XCTFail("expected semantic error")
        } catch {
            XCTAssertFalse(ErrText.isConn(error), "语义错误不得算连接级: \(error)")
        }
        XCTAssertFalse(OfflineGate.isOffline("jdb"))
    }

    func test_21_errTextMapping() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        do {
            _ = try await pool.query(which: "jdb", sql: "SELECT * FROM no_such_table_xx")
        } catch {
            let text = ErrText.of(error)
            XCTAssertTrue(text.contains("表不存在"), text)
        }
    }

    // MARK: SqlPolicy / 池并发

    func test_22_sqlPolicyRejectsUnregistered() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        SqlPolicy.setEnforceForTesting(true)   // 本用例验证准入（setUp 里对基建测试关闭了 enforce）
        do {
            _ = try await pool.query(which: "jdb", sql: "DELETE FROM movies")
            XCTFail("expected SqlPolicyViolation")
        } catch is SqlPolicy.SqlPolicyViolation {
            // 预期：未登记 SQL 直接拒绝
        }
    }

    func test_23_poolConcurrencySixThenMore() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        try await withThrowingTaskGroup(of: Void.self) { grp in
            for i in 0..<10 {
                grp.addTask {
                    _ = try await self.pool.query(
                        which: "jdb",
                        sql: "SELECT ?, ?",
                        params: [.int(Int64(i)), .string("中文\(i)")])
                }
            }
            try await grp.waitForAll()
        }
    }

    func test_24_bothPoolsIndependent() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        async let a = pool.query(which: "jdb", sql: "SELECT 'jdb' AS tag")
        async let b = pool.query(which: "sht", sql: "SELECT 'sht' AS tag")
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra.first?.s("tag"), "jdb")
        XCTAssertEqual(rb.first?.s("tag"), "sht")
    }

    // MARK: Db 门面

    func test_25_dbQueryScalar() async throws {
        try await bootstrapFixture()
        let s = makePoolSettings()
        Db.configure(settingsProvider: { s }, hasNetwork: { true })
        Db.reset()
        let n = try await Db.scalar("jdb", "SELECT COUNT(*) FROM movies")
        XCTAssertEqual(n, 4)
        Db.reset()
    }

    func test_26_dbTablesAndTableOfAndCols() async throws {
        try await bootstrapFixture()
        let s = makePoolSettings()
        Db.configure(settingsProvider: { s }, hasNetwork: { true })
        Db.reset()
        let tables = await Db.tables("sht")
        XCTAssertTrue(tables.contains("movies"))
        let t = await Db.tableOf("sht", "threads")
        XCTAssertEqual(t, "threads")   // fixture 无 sht_threads → 裸名回落
        let cols = await Db.cols("sht", "movies")
        XCTAssertTrue(cols.contains("title"))
        XCTAssertTrue(cols.contains("release_date"))
        Db.reset()
    }

    func test_27_schemaProbeFailureNotCached() async throws {
        let s = makePoolSettings(host: "127.0.0.1", port: 1)
        Db.configure(settingsProvider: { s }, hasNetwork: { true })
        Db.reset()
        let tables = await Db.tables("jdb")
        XCTAssertTrue(tables.isEmpty)
        // 失败不缓存：恢复后能拿到
        let s2 = makePoolSettings()
        Db.configure(settingsProvider: { s2 }, hasNetwork: { true })
        try await bootstrapFixture()
        let tables2 = await Db.tables("jdb")
        XCTAssertTrue(tables2.contains("movies"))
        Db.reset()
    }

    // MARK: TLS（mysql:8 自带自签证书；verify none）

    func test_28_tlsSelfSignedConnect() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings(tls: true))
        let rows = try await pool.query(which: "jdb", sql: "SELECT 1")
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: SOCKS 隧道 E2E（测试内建假 SOCKS5 代理 → mysql）

    func test_29_socksTunnelEndToEnd() async throws {
        try await bootstrapFixture()
        // 假 SOCKS5 代理（无认证，CONNECT 转发到真实 mysql）
        let proxyGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { _ = try? proxyGroup.syncShutdownGracefully() }
        let fakeProxy = FakeSocks5Server(group: proxyGroup,
                                         upstreamHost: Self.host, upstreamPort: Self.port)
        let proxyPort = try await fakeProxy.start()
        // 隧道：入站 127.0.0.1:random → 假代理 → mysql
        let tunnel = Socks5Tunnel(
            proxy: .init(host: "127.0.0.1", port: proxyPort),
            targetHost: Self.host, targetPort: UInt16(Self.port))
        let listenPort = try await tunnel.start()
        defer { Task { await tunnel.destroy() } }
        // MySQLNIO 走隧道（透明中继）
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { _ = try? clientGroup.syncShutdownGracefully() }
        let addr = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: Int(listenPort))
        let conn = try await awaitFuture(
            MySQLConnection.connect(
                to: addr, username: Self.user, database: Self.dbName,
                password: Self.pass, tlsConfiguration: nil, serverHostname: nil,
                on: clientGroup.next()))
        let rows = try await awaitFuture(conn.simpleQuery("SELECT 1"))
        XCTAssertEqual(rows.count, 1)
        let rows2 = try await awaitFuture(
            conn.query("SELECT title FROM movies WHERE id = ?", [MySQLData(string: "m01")]))
        XCTAssertEqual(rows2.first?.column("title")?.string, "演示影片 001")
        _ = try? await awaitFuture(conn.close())
        await fakeProxy.stop()
    }

    func test_30_socksCodecVectors() {
        // 编解码向量（协议正确性）
        XCTAssertEqual(Socks5Codec.greeting(methods: [.noAuth]), [0x05, 0x01, 0x00])
        XCTAssertEqual(
            Socks5Codec.parseGreetingReply([0x05, 0x00]), .noAuth)
        XCTAssertNil(Socks5Codec.parseGreetingReply([0x05, 0xFF]))
        let req = Socks5Codec.connect(host: "192.168.1.5", port: 3307)
        XCTAssertEqual(req, [0x05, 0x01, 0x00, 0x01, 192, 168, 1, 5, 0x0C, 0xEB])
        guard case .succeeded(let h, let p) =
            Socks5Codec.parseConnectReply([0x05, 0x00, 0x00, 0x01, 10, 0, 0, 1, 0x0C, 0xEB]) else {
            return XCTFail()
        }
        XCTAssertEqual(h, "10.0.0.1")
        XCTAssertEqual(p, 3307)
        let domReq = Socks5Codec.connect(host: "db.example.com", port: 3306)
        XCTAssertEqual(domReq[3], 0x03)
        guard let (dh, dp) = Socks5Codec.parseConnectRequest(domReq) else {
            return XCTFail()
        }
        XCTAssertEqual(dh, "db.example.com")
        XCTAssertEqual(dp, 3306)
        XCTAssertTrue(Socks5Codec.parseAuthReply([0x01, 0x00]))
        XCTAssertFalse(Socks5Codec.parseAuthReply([0x01, 0x01]))
    }

    func test_31_rowDuplicateColumnLaterWins() async throws {
        try await bootstrapFixture()
        installPool(makePoolSettings())
        let rows = try await pool.query(
            which: "jdb", sql: "SELECT id AS x, number AS x FROM movies WHERE id = ?",
            params: [.string("m01")])
        XCTAssertEqual(rows.first?.s("x"), "abc-001")   // 同名列后写覆盖（LinkedHashMap 语义）
    }

    func test_32_offlineMarkExpiresByTtl() async throws {
        installPool(makePoolSettings(host: "127.0.0.1", port: 1))
        do {
            _ = try await pool.query(which: "jdb", sql: "SELECT 1")
        } catch {}
        let t0 = OfflineGate.nowMs() + 60_000
        XCTAssertFalse(OfflineGate.isOffline("jdb", now: t0))
        XCTAssertTrue(OfflineGate.isOffline("jdb", now: t0 - 1))
    }
}

// MARK: - 测试用假 SOCKS5 代理（服务端协议 → TCP 转发）

final class FakeSocks5Server {
    private let group: EventLoopGroup
    private let upstreamHost: String
    private let upstreamPort: Int
    private var server: Channel?

    init(group: EventLoopGroup, upstreamHost: String, upstreamPort: Int) {
        self.group = group
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
    }

    func start() async throws -> UInt16 {
        let host = upstreamHost, port = upstreamPort
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(FakeSocksHandler(upHost: host, upPort: port))
            }
        let ch = try await awaitFuture(bootstrap.bind(host: "127.0.0.1", port: 0))
        server = ch
        return UInt16(ch.localAddress?.port ?? 0)
    }

    func stop() async {
        if let s = server {
            _ = try? await awaitFuture(s.close())
        }
    }
}

/// 无认证 SOCKS5 服务端：问候 → 回 00 → CONNECT → 转发 → 泵
final class FakeSocksHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Phase { case greeting, connect, relaying }
    private var phase: Phase = .greeting
    private var accum = ByteBuffer()
    private let upHost: String
    private let upPort: Int
    private var upstream: Channel?

    init(upHost: String, upPort: Int) {
        self.upHost = upHost
        self.upPort = upPort
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var part = Self.unwrapInboundIn(data)
        accum.writeBuffer(&part)
        switch phase {
        case .greeting:
            guard accum.readableBytes >= 2 else { return }
            let n = Int(accum.getInteger(at: accum.readerIndex + 1, as: UInt8.self) ?? 0)
            guard accum.readableBytes >= 2 + n else { return }
            accum.moveReaderIndex(forwardBy: 2 + n)
            var buf = context.channel.allocator.buffer(capacity: 2)
            buf.writeBytes([0x05, 0x00])
            context.writeAndFlush(NIOAny(buf), promise: nil)
            phase = .connect
        case .connect:
            guard accum.readableBytes >= 4 else { return }
            guard let atyp = accum.getInteger(at: accum.readerIndex + 3, as: UInt8.self) else {
                context.close(promise: nil); return
            }
            let need: Int
            switch atyp {
            case 0x01: need = 10
            case 0x03: need = 5 + Int(accum.getInteger(at: accum.readerIndex + 4, as: UInt8.self) ?? 0) + 2
            case 0x04: need = 4 + 16 + 2
            default:
                context.close(promise: nil); return
            }
            guard accum.readableBytes >= need else { return }
            let bytes = accum.getBytes(at: accum.readerIndex, length: need) ?? []
            accum.moveReaderIndex(forwardBy: need)
            guard let target = Socks5Codec.parseConnectRequest(bytes) else {
                context.close(promise: nil); return
            }
            openUpstream(context: context, host: target.host, port: Int(target.port))
            phase = .relaying
        case .relaying:
            guard let upstream else { return }
            var b = accum
            accum = ByteBuffer()
            if b.readableBytes > 0 {
                upstream.writeAndFlush(b, promise: nil)
            }
        }
    }

    private func openUpstream(context: ChannelHandlerContext, host: String, port: Int) {
        let el = context.eventLoop
        ClientBootstrap(group: el)
            .channelInitializer { ch in
                ch.pipeline.addHandler(PumpToHandler(peer: context.channel))
            }
            .connect(host: host, port: port)
            .whenComplete { [weak self] result in
                switch result {
                case .success(let upCh):
                    self?.upstream = upCh
                    var buf = context.channel.allocator.buffer(capacity: 10)
                    buf.writeBytes([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                    context.writeAndFlush(NIOAny(buf), promise: nil)
                    // 建流成功前缓存的字节冲出去
                    if let pending = self?.accum, pending.readableBytes > 0 {
                        upCh.writeAndFlush(pending, promise: nil)
                        self?.accum = ByteBuffer()
                    }
                case .failure:
                    var buf = context.channel.allocator.buffer(capacity: 10)
                    buf.writeBytes([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                    context.writeAndFlush(NIOAny(buf), promise: nil)
                    context.close(promise: nil)
                }
            }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// 上行泵：把本通道收到的字节转发给 peer
final class PumpToHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private weak var peer: Channel?

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = Self.unwrapInboundIn(data)
        peer?.writeAndFlush(b, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
