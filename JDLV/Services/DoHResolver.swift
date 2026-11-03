import Foundation
import JDLVCore

/// DoH 防污染解析（对齐 Android CdnRewrite.dohDns: 阿里公共 DNS, 明文查询会被
/// 污染, 加密后拿到真实 IP; 失败回退系统 DNS）。
///
/// iOS 实现口径（与 Android 的差异, 已记录移植报告）:
/// - Android 用 OkHttp DnsOverHttps 二进制 wireformat（`https://223.5.5.5/dns-query`,
///   bootstrap 223.5.5.5 / 223.6.6.6, bootstrap client connectTimeout 5s）;
/// - iOS 采用阿里 DoH **JSON 接口** `GET /resolve?name=<host>&type=A`
///   （同一服务器同语义, RFC8484 JSON 形态）, 取 Answer 数组中 type=1 (A 记录);
/// - 解析结果暂不接入图片管线的 URLSession（自定义 SNI/证书校验需 session
///   delegate, 本期不做）, 图片请求走系统 DNS —— 见 ImagePipeline 头注释。
enum DoHResolver {
    /// 阿里公共 DNS（bootstrap: 223.5.5.5 / 223.6.6.6, 对齐 Android DoH bootstrap）
    static let serverURL = "https://223.5.5.5/resolve"
    static let BOOTSTRAP = ["223.5.5.5", "223.6.6.6"]
    /// DoH bootstrap client connectTimeout(5s) 对齐
    static let TIMEOUT: TimeInterval = 5
    /// 进程内解析缓存 TTL（DoH 只在图床域名需要, 低频; 避免 DNS 风暴）
    static let CACHE_TTL_MS: Int64 = 5 * 60_000

    private static let lock = NSLock()
    private static var cache: [String: (ips: [String], expiresAt: Int64)] = [:]

    /// 解析 host → IPv4 列表; DoH 失败回退系统 DNS（对齐 Android
    /// `try { doh.lookup(hostname) } catch { Dns.SYSTEM.lookup(hostname) }`）
    static func resolve(host: String) async -> [String] {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.isEmpty { return [] }
        lock.lock()
        if let hit = cache[h], Perf.nowMs() < hit.expiresAt {
            lock.unlock()
            return hit.ips
        }
        lock.unlock()
        let ips = await queryDoH(h)
        if !ips.isEmpty {
            lock.lock()
            cache[h] = (ips, Perf.nowMs() + CACHE_TTL_MS)
            lock.unlock()
            return ips
        }
        return systemResolve(h)
    }

    /// DoH JSON 查询: {"Status":0,"Answer":[{"name":..,"type":1,"TTL":..,"data":"1.2.3.4"},..]}
    private static func queryDoH(_ host: String) async -> [String] {
        guard var comps = URLComponents(string: serverURL) else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = TIMEOUT
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = obj["Answer"] as? [[String: Any]] else { return [] }
            var out: [String] = []
            for a in answers {
                // type 字段兼容数值/字符串形态; 1 = A 记录
                let t: Int
                if let n = a["type"] as? NSNumber {
                    t = n.intValue
                } else if let s = a["type"] as? String {
                    t = Int(s) ?? 0
                } else {
                    t = 0
                }
                if t == 1, let d = a["data"] as? String { out.append(d) }
            }
            return out
        } catch {
            return []
        }
    }

    /// 系统 DNS 回退（getaddrinfo, AF_INET; 对齐 Dns.SYSTEM）
    static func systemResolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, res != nil else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = res
        while let cur = p {
            if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr {
                let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = sin.sin_addr
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    out.append(String(cString: buf))
                }
            }
            p = cur.pointee.ai_next
        }
        return out
    }
}
