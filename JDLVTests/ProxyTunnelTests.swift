import XCTest
import Network
@testable import JDLV
import JDLVCore

//
//  ProxyTunnelTests.swift —— A2/R2 数据库 SOCKS5 隧道契约测试（R-V4）。
//
//  覆盖：
//  - 隧道生命周期：reconcile(proxyDb=true) → 监听 127.0.0.1 随机端口 + 无错误；
//  - CONNECT 目标 = 真实 db host:port（假 SOCKS 代理逐字节解析记录）；
//  - override 合并：host=127.0.0.1 / port=listenPort / serverHostname=真实 host（SNI 保留）、
//    口令/库名每次从 base 实时取（不冻结在 override）；
//  - 失败保留旧配置：非法代理端口 → lastError 非空、旧隧道与 override 原样；
//  - 关闭开关：override 清空（serverHostname 回落直连）+ 隧道销毁；
//  - 真实链路（CI env 注入 fixture MySQL；本地 Skip）：mysql-nio → 回环隧道 →
//    假 SOCKS 中继 → 真实 MySQL 8：Db.check 成功 + Db.query("select 1") 1 行
//    （R-V4「MySQLNIO 连回环端口」）。
//

// MARK: - 假 SOCKS5 代理（NWListener：greeting→0x00、CONNECT→记录并回成功、之后双向中继）

private final class FakeSocks5Server {
    let q = DispatchQueue(label: "fake_socks")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private let lock = NSLock()
    private var _connects: [(String, UInt16)] = []
    private var _connCount = 0
    private var _events: [String] = []
    /// 强持有连接处理器（否则创建即释放，状态回调永不触发）
    private var _handlers: [FakeSocksConn] = []

    var connects: [(String, UInt16)] {
        lock.lock(); defer { lock.unlock() }
        return _connects
    }

    var connCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _connCount
    }

    /// 诊断事件流（ready/accept/failed…；测试失败时随断言输出）
    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    fileprivate func record(_ e: String) {
        lock.lock(); _events.append(e); lock.unlock()
    }

    func start() async throws {
        // 首选显式回环 IPv4 绑定（避免 .any 双栈歧义 → NIO IPv4 connect 打不到监听）；
        // 3s 未就绪则回退通配绑定
        let paramsList: [NWParameters] = [Self.loopbackParams(), NWParameters.tcp]
        for (idx, params) in paramsList.enumerated() {
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener
            let ready = ReadyGate()
            listener.stateUpdateHandler = { [weak ready, weak self] (state: NWListener.State) in
                if case .ready = state { ready?.fire() }
                if case .failed(let e) = state { self?.record("listener-failed:\(e)") }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.lock.lock(); self._connCount += 1; self._events.append("accept"); self.lock.unlock()
                let handler = FakeSocksConn(conn: conn, server: self)
                self.lock.lock(); self._handlers.append(handler); self.lock.unlock()
                handler.start()
            }
            listener.start(queue: q)
            await ready.fulfillWait(timeout: 3)
            if let p = listener.port?.rawValue, p > 0 {
                port = p
                record("ready(idx=\(idx)) port=\(p)")
                return
            }
            listener.cancel()
        }
        throw NSError(domain: "FakeSocks5Server", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "listener 未就绪: \(events.joined(separator: " | "))"])
    }

    private static func loopbackParams() -> NWParameters {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        return p
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    fileprivate func recordConnect(_ host: String, _ port: UInt16) {
        lock.lock(); _connects.append((host, port)); lock.unlock()
    }

    /// 等待门（NW 回调在自有 queue → 用 continuation 桥 async；带超时兜底防悬挂）
    private final class ReadyGate {
        private var cont: CheckedContinuation<Void, Never>?
        private let lock = NSLock()
        private var done = false

        func fulfillWait(timeout: TimeInterval) async {
            if lock.withLock({ done }) { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { self.timeoutFire() }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if done { lock.unlock(); c.resume(); return }
                cont = c
                lock.unlock()
            }
        }

        private func timeoutFire() {
            lock.lock()
            let first = !done
            done = true
            let c = cont
            cont = nil
            lock.unlock()
            if first { c?.resume() }
        }

        func fire() {
            lock.lock()
            let first = !done
            done = true
            let c = cont
            cont = nil
            lock.unlock()
            if first { c?.resume() }
        }
    }
}

/// 单条入站连接处理（SOCKS5 握手 + 中继）
private final class FakeSocksConn {
    private enum Phase { case greeting, connect, relay }
    private let conn: NWConnection
    private let server: FakeSocks5Server
    private var buf = Data()
    private var phase: Phase = .greeting
    private var backend: NWConnection?

    fileprivate func phaseName() -> String {
        switch phase {
        case .greeting: return "greeting"
        case .connect: return "connect"
        case .relay: return "relay"
        }
    }

    init(conn: NWConnection, server: FakeSocks5Server) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready:
                self?.server.record("conn-ready")
                self?.receiveInbound()
            case .failed(let e):
                self?.server.record("conn-failed:\(e)")
                self?.teardown()
            case .cancelled:
                self?.teardown()
            default: break
            }
        }
        conn.start(queue: server.q)
    }

    private func receiveInbound() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.server.record("recv:\(data.count)b phase=\(self.phaseName())")
                buf.append(data)
                process()
            }
            if complete || error != nil {
                teardown()
                return
            }
            receiveInbound()
        }
    }

    private func process() {
        switch phase {
        case .greeting:
            guard buf.count >= 2 else { return }
            buf.removeFirst(2)
            sendInbound(Data([0x05, 0x00]))
            phase = .connect
        case .connect:
            guard let req = Socks5Codec.parseConnectRequest([UInt8](buf)) else { return }
            server.recordConnect(req.host, req.port)
            buf.removeAll()
            sendInbound(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            phase = .relay
            connectBackend(host: req.host, port: Int(req.port))
        case .relay:
            guard !buf.isEmpty else { return }
            let d = buf
            buf.removeAll()
            backend?.send(content: d, completion: .contentProcessed { _ in })
        }
    }

    private func connectBackend(host: String, port: Int) {
        let ep = NWEndpoint.Host(host)
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            teardown()
            return
        }
        let be = NWConnection(host: ep, port: p, using: .tcp)
        backend = be
        be.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready: self?.receiveBackend()
            case .failed, .cancelled: self?.teardown()
            default: break
            }
        }
        be.start(queue: server.q)
    }

    private func receiveBackend() {
        backend?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                sendInbound(data)
            }
            if complete || error != nil {
                teardown()
                return
            }
            receiveBackend()
        }
    }

    private func sendInbound(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func teardown() {
        conn.cancel()
        backend?.cancel()
        backend = nil
    }
}

// MARK: - 测试

final class ProxyTunnelTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval,
                           _ cond: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "ProxyTunnelTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "waitUntil timeout"])
    }

    /// 打开一条到隧道的原始 TCP（触发 tunnel→proxy 的 CONNECT），由调用方关闭
    private func probeTunnel(_ port: UInt16) async throws -> NWConnection {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ProxyTunnelTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: p, using: .tcp)
        let gate = ProbeGate()
        conn.stateUpdateHandler = { (state: NWConnection.State) in
            if case .ready = state { gate.fire() }
        }
        conn.start(queue: .global())
        try await gate.wait(seconds: 5)
        return conn
    }

    private final class ProbeGate {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        private var fired = false

        func fire() {
            lock.lock(); fired = true; let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: ())
        }

        func wait(seconds: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if fired { lock.unlock(); c.resume(returning: ()); return }
                cont = c
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    self.lock.lock()
                    let pending = self.cont
                    self.cont = nil
                    self.lock.unlock()
                    pending?.resume(throwing: NSError(domain: "ProbeGate", code: 3,
                                                      userInfo: [NSLocalizedDescriptionKey: "probe timeout"]))
                }
            }
        }
    }

    override func tearDown() async throws {
        await ProxyTunnelManager.shared.resetForTests()
        AppBootstrap.box.update(AppSettings())
        AppBootstrap.injectRuntime()
        CdnRewrite.settingsProvider = { CdnSettings() }
        Socks5TunnelDebug.sink = nil
        try await super.tearDown()
    }

    // MARK: 生命周期 + CONNECT 目标 + override 合并 + 关闭

    @MainActor
    func testTunnelLifecycleConnectTargetAndOverride() async throws {
        let fake = FakeSocks5Server()
        try await fake.start()
        defer { fake.stop() }
        try await waitUntil(timeout: 3) { fake.port > 0 }

        var s = AppSettings()
        s.proxyDb = true
        s.proxyHost = "127.0.0.1"
        s.proxyPort = String(fake.port)
        s.remoteHost = "203.0.113.9"   // TEST-NET-3（不可达，仅校验 CONNECT 记录）
        s.remotePort = "3307"
        s.remoteUser = "u_t"
        s.remotePass = "p_t"

        let mgr = ProxyTunnelManager.shared
        await mgr.reconcileAndWait(s)
        let listen = mgr.activeListenPort
        XCTAssertNotNil(listen, "隧道应已监听")
        XCTAssertNil(mgr.lastError)
        // 隧道握手观测（失败时随断言输出）
        var tunnelEvents: [String] = []
        Socks5TunnelDebug.sink = { tunnelEvents.append($0) }

        // override 合并：传输三元组替换 + SNI 保留 + 其余字段实时取自 base
        let base = try XCTUnwrap(AppBootstrap.mysqlSettings(s))
        let eff = try XCTUnwrap(ProxyTunnelManager.effectiveSettings(base))
        XCTAssertEqual(eff.host, "127.0.0.1")
        XCTAssertEqual(eff.port, Int(try XCTUnwrap(listen)))
        XCTAssertEqual(eff.serverHostname, "203.0.113.9")
        XCTAssertEqual(eff.pass, "p_t")
        XCTAssertEqual(eff.jdbDb, "javdb")

        // 一条入站连接 → tunnel 向假代理发 CONNECT（目标 = 真实 host:port）
        let probe = try await probeTunnel(try XCTUnwrap(listen))
        defer { probe.cancel() }
        if fake.connects.isEmpty {
            try await waitUntil(timeout: 5) { !fake.connects.isEmpty }
        }
        guard let first = fake.connects.first else {
            XCTFail("CONNECT 未到达假代理: connCount=\(fake.connCount) fakeEvents=\(fake.events.joined(separator: " | ")) " +
                    "tunnelEvents=\(tunnelEvents.joined(separator: " | "))")
            return
        }
        XCTAssertEqual(first.0, "203.0.113.9")
        XCTAssertEqual(first.1, 3307)

        // 关闭开关：override 清空 + 端口复位（destroy 语义）
        s.proxyDb = false
        await mgr.reconcileAndWait(s)
        XCTAssertNil(mgr.activeListenPort)
        XCTAssertNil(try XCTUnwrap(ProxyTunnelManager.effectiveSettings(base)).serverHostname)
        XCTAssertEqual(try XCTUnwrap(ProxyTunnelManager.effectiveSettings(base)).host, "203.0.113.9")
    }

    // MARK: 失败保留旧配置

    @MainActor
    func testInvalidProxyKeepsPreviousConfig() async throws {
        let fake = FakeSocks5Server()
        try await fake.start()
        defer { fake.stop() }

        var s = AppSettings()
        s.proxyDb = true
        s.proxyHost = "127.0.0.1"
        s.proxyPort = String(fake.port)
        s.remoteHost = "203.0.113.9"
        s.remotePort = "3307"
        s.remoteUser = "u_t"
        s.remotePass = "p_t"

        let mgr = ProxyTunnelManager.shared
        await mgr.reconcileAndWait(s)
        let before = mgr.activeListenPort
        XCTAssertNotNil(before)

        s.proxyPort = "0"   // 非法端口 → 收敛失败
        await mgr.reconcileAndWait(s)
        XCTAssertNotNil(mgr.lastError, "失败必须置 lastError")
        XCTAssertEqual(mgr.activeListenPort, before, "失败必须保留旧隧道")
        let eff = try XCTUnwrap(ProxyTunnelManager.effectiveSettings(try XCTUnwrap(AppBootstrap.mysqlSettings(s))))
        XCTAssertEqual(eff.port, Int(try XCTUnwrap(before)), "失败必须保留旧 override")
    }

    // MARK: 真实链路：mysql-nio → 回环隧道 → 假 SOCKS → 真实 MySQL（R-V4 底线）

    @MainActor
    func testRealMySQLThroughTunnel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JDLV_TEST_MYSQL_HOST"] else {
            throw XCTSkip("本地无 MySQL fixture（CI ios job 注入 JDLV_TEST_MYSQL_*）")
        }
        let port = Int(env["JDLV_TEST_MYSQL_PORT"] ?? "3306") ?? 3306
        let user = env["JDLV_TEST_MYSQL_USER"] ?? "root"
        let pass = env["JDLV_TEST_MYSQL_PASS"] ?? ""

        let fake = FakeSocks5Server()
        try await fake.start()
        defer { fake.stop() }

        var s = AppSettings()
        s.proxyDb = true
        s.proxyHost = "127.0.0.1"
        s.proxyPort = String(fake.port)
        s.remoteHost = host
        s.remotePort = String(port)
        s.remoteUser = user
        s.remotePass = pass
        s.remoteJdb = "jdlv_app_it"
        s.remoteSht = "jdlv_app_it"
        s.dbSsl = false
        s.connectTimeout = 5
        s.queryTimeout = 8

        // 生产同一入口：AppBootstrap 快照 → injectRuntime → effectiveSettings 合并隧道
        AppBootstrap.box.update(s)
        AppBootstrap.injectRuntime()

        let mgr = ProxyTunnelManager.shared
        await mgr.reconcileAndWait(s)
        XCTAssertNotNil(mgr.activeListenPort)
        XCTAssertNil(mgr.lastError)
        var tunnelEvents: [String] = []
        Socks5TunnelDebug.sink = { tunnelEvents.append($0) }

        let ok = await Db.check("jdb")
        if !ok {
            XCTFail("经回环隧道连真实 MySQL 失败（lastError=\(mgr.lastError ?? "-")；" +
                    "fake connCount=\(fake.connCount) fakeEvents=\(fake.events.joined(separator: " | ")) " +
                    "tunnelEvents=\(tunnelEvents.joined(separator: " | "))）")
            return
        }
        let rows = try await Db.query("jdb", "select 1")
        XCTAssertEqual(rows.count, 1)

        if fake.connects.isEmpty {
            try await waitUntil(timeout: 5) { !fake.connects.isEmpty }
        }
        guard let first = fake.connects.first else {
            XCTFail("CONNECT 未到达假代理: connCount=\(fake.connCount) events=\(fake.events.joined(separator: " | "))")
            return
        }
        XCTAssertEqual(first.0, host, "CONNECT 目标必须是真实 host")
        XCTAssertEqual(first.1, UInt16(port), "CONNECT 目标必须是真实 port")
    }
}
