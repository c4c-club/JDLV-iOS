import XCTest
@testable import JDLV

// R3 问题 2：图床代理探测单测（13 §6.1 ProxyProbeTests —— URLProtocol mock）。
// 覆盖：成功 / 403 / 未配置 / HEAD 回落 GET / 代理字典包含 host:port；绝不触 DB。
final class ProxyProbeTests: XCTestCase {

    // MARK: URLProtocol mock

    final class MockURLProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (Int, [String: String], Data?))? = nil
        static var lastRequest: URLRequest? = nil

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            let (code, headers, data) = Self.handler?(request) ?? (200, [:], nil)
            let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func probe(_ s: AppSettings) async -> ProxyProbeResult {
        await ProxyProbe.test(s) { cfg in
            cfg.protocolClasses = [MockURLProtocol.self]
        }
    }

    private var settings: AppSettings {
        var s = AppSettings()
        s.proxyHost = "10.0.0.2"
        s.proxyPort = "7890"
        s.proxyCdnJdb = true
        s.jdbImgHost = "https://img.example.com"
        return s
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testSuccess200() async {
        MockURLProtocol.handler = { req in
            (200, ["Content-Type": "image/jpeg"], Data(repeating: 1, count: 128))
        }
        let r = await probe(settings())
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.message.hasPrefix("✓ 代理可访问图床"), "成功文案以图床开头：\(r.message)")
        XCTAssertTrue(r.message.contains("https://img.example.com"))
        XCTAssertTrue(r.message.contains("200"))
        XCTAssertEqual(r.status, 200)
    }

    func test403ProxyReachableImageHostDenied() async {
        MockURLProtocol.handler = { _ in (403, [:], nil) }
        let r = await probe(settings())
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("代理可达但图床拒绝"), "403 = 代理可达图床拒绝：\(r.message)")
        XCTAssertTrue(r.message.contains("403"))
    }

    func testHead405FallsBackToGet() async {
        MockURLProtocol.handler = { req in
            if req.httpMethod == "HEAD" { return (405, [:], nil) }
            return (200, ["Content-Type": "image/png"], Data([1]))
        }
        let r = await probe(settings())
        XCTAssertTrue(r.ok)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET",
                       "HEAD 405 → 回落 GET")
    }

    func testUnconfiguredTarget() async {
        var s = AppSettings()
        s.proxyCdnJdb = false
        s.proxyCdnSht = false
        s.jdbImgHost = ""
        s.shtMirrorHost = ""
        s.shtMirror = ""
        let r = await probe(s)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message, "未配置图床地址，无法测试代理")
    }

    func testProxyDictionaryContainsHostPort() {
        let d = ProxyProbe.proxyDictionary(host: "10.0.0.2", port: 7890)
        XCTAssertEqual(d[kCFNetworkProxiesHTTPProxy as String] as? String, "10.0.0.2")
        XCTAssertEqual(d[kCFNetworkProxiesHTTPPort as String] as? Int, 7890)
        XCTAssertEqual(d[kCFNetworkProxiesHTTPSProxy as String] as? String, "10.0.0.2")
        XCTAssertNil(d[kCFNetworkProxiesSOCKSProxy as String], "非 1080 端口不加 SOCKS 键")

        let socks = ProxyProbe.proxyDictionary(host: "127.0.0.1", port: 1080)
        XCTAssertEqual(socks[kCFNetworkProxiesSOCKSProxy as String] as? String, "127.0.0.1")
    }

    func testTargetPriorityOrder() {
        var s = AppSettings()
        s.proxyCdnJdb = true
        s.jdbImgHost = "https://jdb-host"
        s.proxyCdnSht = true
        s.shtMirrorHost = "https://sht-host"
        s.shtMirror = "https://mirror"
        XCTAssertEqual(ProxyProbe.target(of: s), "https://jdb-host", "优先 jdb 图床")

        s.proxyCdnJdb = false
        XCTAssertEqual(ProxyProbe.target(of: s), "https://sht-host", "次选 sht 镜像 host")

        s.proxyCdnSht = false
        XCTAssertEqual(ProxyProbe.target(of: s), "https://mirror", "兜底 shtMirror")
    }

    func testNeverTouchesDatabaseSymbols() {
        // 结构性断言：ProxyProbe 无 Db/MySQL 依赖（编译期由 import 面保证；
        // 本用例锁定目标选择与 DB 设置无关）
        var s = AppSettings()
        s.remoteHost = "192.168.1.1"
        s.remotePort = "3306"
        XCTAssertNil(ProxyProbe.target(of: s), "未配图床 → 不探测（与数据库配置无关）")
    }
}
