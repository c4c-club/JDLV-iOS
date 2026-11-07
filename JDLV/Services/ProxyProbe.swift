import Foundation
import JDLVCore

//
//  ProxyProbe.swift —— 代理 → 图床探测（R3 问题 2：测图床，不是数据库）。
//
//  与 SettingsDiagnostics.testConnection（DB ping）彻底分离：本组件绝不调用
//  Db.check / Db.query / Db.reset / bumpData。
//  - 目标：优先 jdbImgHost（proxyCdnJdb 开）→ shtMirrorHost（proxyCdnSht 开）→
//    shtMirror；全空 → 「未配置图床地址，无法测试代理」。
//  - URLSessionConfiguration.ephemeral + connectionProxyDictionary（HTTP/HTTPS 键；
//    端口为 SOCKS 约定 1080 时另加 SOCKS 键）。
//  - HEAD（405/404/501 回落 GET）；timeout 10s；记录 status/ms/Content-Type/bytes。
//  - 成功判定：拿到响应且 200...399；401/403 = 代理可达但图床拒绝。
//

struct ProxyProbeResult: Equatable {
    var ok: Bool
    var target: String
    var status: Int
    var ms: Int
    var detail: String
    var message: String   // UI 直接展示
}

enum ProxyProbe {

    static let timeoutInterval: TimeInterval = 10

    /// 目标选择（13 §5.1 顺序）；只接受 http(s) URL（jdbImgHost 默认值 "app" 非 URL）
    static func target(of s: AppSettings) -> String? {
        let normalize: (String) -> String? = { raw in
            let u = CdnRewrite.normalizeUrl(raw)
            guard u.hasPrefix("http://") || u.hasPrefix("https://") else { return nil }
            return u
        }
        if s.proxyCdnJdb, let u = normalize(s.jdbImgHost) { return u }
        if s.proxyCdnSht, let u = normalize(s.shtMirrorHost) { return u }
        if let u = normalize(s.shtMirror) { return u }
        return nil
    }

    /// 代理字典（HTTP/HTTPS；socks 端口约定 1080 另加 SOCKS 键）
    static func proxyDictionary(host: String, port: Int) -> [AnyHashable: Any] {
        var d: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        if port == 1080 {
            d[kCFNetworkProxiesSOCKSEnable as String] = true
            d[kCFNetworkProxiesSOCKSProxy as String] = host
            d[kCFNetworkProxiesSOCKSPort as String] = port
        }
        return d
    }

    /// 探测（URLSession 可注入 protocolClasses 供单测 mock）
    static func test(_ s: AppSettings,
                     sessionConfiguration: ((URLSessionConfiguration) -> Void)? = nil) async -> ProxyProbeResult {
        guard let target = target(of: s) else {
            return ProxyProbeResult(ok: false, target: "", status: 0, ms: 0, detail: "",
                                    message: "未配置图床地址，无法测试代理")
        }
        guard let url = URL(string: target) else {
            return ProxyProbeResult(ok: false, target: target, status: 0, ms: 0, detail: "",
                                    message: "✗ 图床地址无效 · \(target)")
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutInterval
        cfg.timeoutIntervalForResource = timeoutInterval
        if !s.proxyHost.isEmpty, let port = Int(s.proxyPort), port > 0, port <= 65535 {
            cfg.connectionProxyDictionary = proxyDictionary(host: s.proxyHost, port: port)
        }
        sessionConfiguration?(cfg)
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: timeoutInterval)
        req.httpMethod = "HEAD"

        let started = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        do {
            var (data, resp) = try await session.data(for: req)
            var response = resp as? HTTPURLResponse
            // HEAD 不被图床支持 → 回落 GET
            if let code = response?.statusCode, [404, 405, 501].contains(code) {
                req.httpMethod = "GET"
                (data, resp) = try await session.data(for: req)
                response = resp as? HTTPURLResponse
            }
            let ms = elapsedMs()
            let code = response?.statusCode ?? 0
            let ctype = (response?.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            let bytes = data.count
            let detail = "status=\(code) ms=\(ms) type=\(ctype.isEmpty ? "-" : ctype) bytes=\(bytes)"
            if (200...399).contains(code) {
                return ProxyProbeResult(
                    ok: true, target: target, status: code, ms: ms, detail: detail,
                    message: "✓ 代理可访问图床 · \(target) · \(code) · \(ms) ms"
                        + (ctype.isEmpty ? "" : " · \(ctype)"))
            }
            let hint = (code == 401 || code == 403)
                ? "代理可达但图床拒绝"
                : "图床返回错误状态"
            return ProxyProbeResult(
                ok: false, target: target, status: code, ms: ms, detail: detail,
                message: "✗ \(hint) · \(target) · \(code) · \(ms) ms")
        } catch {
            let ms = elapsedMs()
            let chain: String
            if let urlErr = error as? URLError {
                chain = "URLError.\(urlErr.code.rawValue) · \(urlErr.localizedDescription)"
            } else {
                chain = error.localizedDescription
            }
            return ProxyProbeResult(
                ok: false, target: target, status: 0, ms: ms, detail: chain,
                message: "✗ 代理不可用 · \(s.proxyHost.isEmpty ? "(未配置代理)" : "\(s.proxyHost):\(s.proxyPort)") · \(chain)")
        }
    }
}
