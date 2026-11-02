import Foundation

/// 反查跳转载荷：JSON{ label, sort?, f:{12 字段} } → Base64 URL-safe 无填充（UTF-8）。
/// 解码失败 → nil（调用方兜底空态，绝不崩溃）。
public struct LookupSpec: Equatable {
    public var filters: Filters
    public var label: String
    public var sort: String?

    public init(filters: Filters = Filters(), label: String = "反查", sort: String? = nil) {
        self.filters = filters
        self.label = label
        self.sort = sort
    }
}

public enum LookupCodec {
    private struct Payload: Codable {
        var label: String
        var sort: String?
        var f: Filters
    }

    public static func encode(_ spec: LookupSpec) -> String {
        let payload = Payload(label: spec.label, sort: spec.sort, f: spec.filters)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload) else { return "" }
        return base64UrlNoPad(data)
    }

    public static func decode(_ payload: String) -> LookupSpec? {
        guard let data = dataFromBase64UrlNoPad(payload) else { return nil }
        let decoder = JSONDecoder()
        guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
        return LookupSpec(filters: p.f, label: p.label, sort: p.sort)
    }

    // MARK: - Base64 URL-safe 无填充

    static func base64UrlNoPad(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    static func dataFromBase64UrlNoPad(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem == 2 { t += "==" } else if rem == 3 { t += "=" } else if rem == 1 { return nil }
        return Data(base64Encoded: t)
    }
}
