import Foundation
import JDLVCore

/// 图床自检结果（对齐 Android CdnSelfTest.ProbeResult; kind/success/host/detail
/// 为任务要求的出口形态, 其余字段与 Android 逐字一致）
struct SelfTestResult {
    let kind: String      // app / web / sht / ext
    let url: String
    let code: Int         // 0 = 网络/异常 (err 说明)
    let bytes: Int
    let decoded: Bool
    let ms: Int64
    let err: String       // 空 = 成功

    var success: Bool { err.isEmpty }
    var host: String { url.isEmpty ? "" : CdnRewrite.hostOnly(url) }
    /// 设置页展示用一行明细
    var detail: String {
        err.isEmpty
            ? "HTTP \(code) · \(bytes)B · \(decoded ? "已解码" : "未解码") · \(ms)ms"
            : err
    }
}

/**
 * 图床自检 —— 设置页一键探测四类图床, 以后任何图床问题都能一眼看出是哪一类、
 * 什么错（HTTP 码 / 字节数 / 是否解码 / 耗时）。★ S12-P3 (docs/70 P3.1)。
 *
 * 取样规则（每类 1 条, 全部从远程库现取, 取不到就用内置样例）:
 * **禁止前导通配 LIKE**（`LIKE '%/covers/%'` 在 100 万行上是 50 秒级）, 一律先用
 * 索引序取一小批再在内存里挑:
 *   app → SELECT id, cover_url FROM movies ORDER BY release_date DESC LIMIT 30
 *         客户端挑第一个含 "/covers/" 的 cover_url (都没有 → 内置样例)
 *   web → app 样例同路径换 c0.jdbstatic.com host (仅"是否可达"结论)
 *   sht → SELECT tid, url FROM <thread_images> ORDER BY tid DESC LIMIT 20
 *         客户端挑第一个 http 开头的 url (没有 → 跳过, "库内暂无样例")
 *   ext → SELECT content_html FROM articles ORDER BY released_at DESC LIMIT 5
 *         正则抽第一个 host 既非 spfcas 也非 jdbstatic 的图 (没有 → 跳过)
 *
 * 执行: 走 ImagePipeline.fetchRaw（与图片加载同链路: 代理/UA/Referer 一致）,
 * 读全 body (≤2MB); app/web 过 deobfuscateAuto + isImageMagic 判 decoded。
 * SQL 均已登记 SqlPolicy（img.selftest.*）。
 */
enum CdnSelfTest {
    /// app 类内置兜底样例（docs/70 §1.4 实抓 200 + 可解码）
    static let FALLBACK_APP_URL = "https://tp.spfcas.com/rhe951l4q/covers/z4/z49rR4.jpg"

    /// 响应体上限 2MB
    static let BODY_LIMIT = 2 * 1024 * 1024

    static let EXT_IMG_RE = try! NSRegularExpression(
        pattern: "<img[^>]+src=[\"']([^\"']+)[\"']", options: [.caseInsensitive])

    /// 四类各取 1 条实测; 顺序 app → web → sht → ext（单条失败不拖垮其它类）
    static func run() async -> [SelfTestResult] {
        var out: [SelfTestResult] = []
        let appUrl = await sampleAppCover()
        out.append(await probe("app", appUrl, decode: true))
        // web: 同路径换 web host (c0 实测本机不可达 → 预期 Reset/超时, err 给具体原因)
        let path = CdnRewrite.imgPathOf(appUrl)
        out.append(await probe("web", path != nil ? CdnRewrite.WEB_CDN + path! : "", decode: true))
        let shtUrl = await sampleShtImage()
        if let shtUrl {
            out.append(await probe("sht", shtUrl, decode: false))
        } else {
            out.append(SelfTestResult(kind: "sht", url: "", code: 0, bytes: 0,
                                      decoded: false, ms: 0, err: "库内暂无样例"))
        }
        let extUrl = await sampleExternal()
        if let extUrl {
            out.append(await probe("ext", extUrl, decode: false))
        } else {
            out.append(SelfTestResult(kind: "ext", url: "", code: 0, bytes: 0,
                                      decoded: false, ms: 0, err: "库内暂无样例"))
        }
        return out
    }

    /// 单条探测: GET 全 body → (解码) → 魔数验证; 异常一律转 err 文本, 不抛
    static func probe(_ kind: String, _ url: String, decode: Bool) async -> SelfTestResult {
        if url.isEmpty {
            return SelfTestResult(kind: kind, url: url, code: 0, bytes: 0,
                                  decoded: false, ms: 0, err: "无样例")
        }
        let t0 = Perf.nowMs()
        do {
            let (data, code) = try await ImagePipeline.shared.fetchRaw(
                url: url, kind: cdnKind(kind))
            let ms = Perf.nowMs() - t0
            if !(200..<300).contains(code) {
                return SelfTestResult(kind: kind, url: url, code: code, bytes: 0,
                                      decoded: false, ms: ms, err: "HTTP \(code)")
            }
            if data.isEmpty {
                return SelfTestResult(kind: kind, url: url, code: code, bytes: 0,
                                      decoded: false, ms: ms, err: "空响应体")
            }
            if data.count > BODY_LIMIT {
                return SelfTestResult(kind: kind, url: url, code: code, bytes: data.count,
                                      decoded: false, ms: ms, err: "响应超 2MB")
            }
            let decoded = decode
                ? CdnRewrite.isImageMagic(CdnRewrite.deobfuscateAuto(data))
                : CdnRewrite.isImageMagic(data)
            return SelfTestResult(kind: kind, url: url, code: code, bytes: data.count,
                                  decoded: decoded, ms: ms,
                                  err: decoded ? "" : "非图片 (魔数不符)")
        } catch {
            let ms = Perf.nowMs() - t0
            let name = String(describing: type(of: error))
            let msg = (error as? CustomStringConvertible)?.description
                ?? error.localizedDescription
            return SelfTestResult(kind: kind, url: url, code: 0, bytes: 0,
                                  decoded: false, ms: ms,
                                  err: "\(name): \(String(msg.prefix(60)))")
        }
    }

    // MARK: - R7-P5 头像/封面连通性自检

    /// 头像自检单条结果: host + 路径段, 不含完整 URL 与查询串（任务 06 步骤 4）
    struct AvatarProbeResult {
        let isAvatar: Bool     // true=avatar_url / false=cover
        let host: String
        let pathSeg: String    // /avatars / /covers / other
        let code: Int          // 0 = 传输层异常
        let ms: Int64
        let altUsed: Bool
        let ok: Bool
        let err: String

        var line: String {
            let tag = isAvatar ? "avatar" : "cover"
            let altText = altUsed ? " · alt=1" : ""
            return ok
                ? "\(tag) \(host)\(pathSeg) HTTP \(code)\(altText) · \(ms)ms OK"
                : "\(tag) \(host)\(pathSeg) code=\(code == 0 ? "ERR" : String(code)) · \(err)"
        }
    }

    /// 女优头像样例: videos_count 序 30 条, 内存挑非空 avatar_url 前 3
    /// （img.selftest.avatar; 异常 → 空）
    private static func sampleAvatars() async -> [String] {
        do {
            let rows = try await Db.query(
                "jdb", "SELECT id, avatar_url FROM actors ORDER BY videos_count DESC LIMIT 30")
            return rows.map { $0.s("avatar_url") }.filter { !$0.isEmpty }.prefix(3).map { $0 }
        } catch {
            return []
        }
    }

    /// app 封面样例: 索引序取 30 条, 内存挑含 /covers/ 的前 n 条（img.selftest.movie; 异常 → 兜底样例）
    private static func sampleAppCovers(_ n: Int) async -> [String] {
        do {
            let rows = try await Db.query(
                "jdb", "SELECT id, cover_url FROM movies ORDER BY release_date DESC LIMIT 30")
            let hits = rows.map { $0.s("cover_url") }.filter { $0.contains("/covers/") }
            if hits.count >= n { return Array(hits.prefix(n)) }
            return hits + Array(repeating: FALLBACK_APP_URL, count: n - hits.count)
        } catch {
            return Array(repeating: FALLBACK_APP_URL, count: n)
        }
    }

    /// 头像/封面探测: 先过 jdbImgUrl（与真实加载同链路重写, avatars 强制 APP CDN）→
    /// GET（fetchRaw 含代理回退）→ 失败再 altJdbImgUrl 一次并记录 altUsed
    static func probeImage(_ raw: String, isAvatar: Bool) async -> AvatarProbeResult {
        let u = CdnRewrite.jdbImgUrl(raw)
        let host = CdnRewrite.hostOnly(u)
        let segs = CdnRewrite.imgPathOf(u)?.split(separator: "/") ?? []
        let pathSeg = "/\(segs.first.map(String.init) ?? "other")"
        let t0 = Perf.nowMs()
        do {
            let (_, code) = try await ImagePipeline.shared.fetchRaw(url: u, kind: CdnRewrite.kindOf(u))
            let ms = Perf.nowMs() - t0
            if (200..<300).contains(code) {
                return AvatarProbeResult(isAvatar: isAvatar, host: host, pathSeg: pathSeg,
                                         code: code, ms: ms, altUsed: false, ok: true, err: "")
            }
            return await probeAlt(u, host: host, pathSeg: pathSeg, isAvatar: isAvatar,
                                  firstCode: code, ms0: ms)
        } catch {
            let ms = Perf.nowMs() - t0
            return await probeAlt(u, host: host, pathSeg: pathSeg, isAvatar: isAvatar,
                                  firstCode: 0, ms0: ms,
                                  firstErr: String(describing: type(of: error)))
        }
    }

    /// 失败后的备用图床确认（一次）; alt 也不通 → 汇总失败
    private static func probeAlt(_ u: String, host: String, pathSeg: String, isAvatar: Bool,
                                 firstCode: Int, ms0: Int64, firstErr: String = "") async -> AvatarProbeResult {
        let t1 = Perf.nowMs()
        if let altUrl = CdnRewrite.altJdbImgUrl(u),
           let (_, code2) = try? await ImagePipeline.shared.fetchRaw(url: altUrl, kind: CdnRewrite.kindOf(altUrl)),
           (200..<300).contains(code2) {
            return AvatarProbeResult(isAvatar: isAvatar, host: host, pathSeg: pathSeg,
                                     code: code2, ms: ms0 + (Perf.nowMs() - t1),
                                     altUsed: true, ok: true, err: "")
        }
        let err = firstErr.isEmpty
            ? (firstCode == 0 ? "transport, alt 亦失败" : "HTTP \(firstCode), alt 亦失败")
            : "\(firstErr), alt 亦失败"
        return AvatarProbeResult(isAvatar: isAvatar, host: host, pathSeg: pathSeg,
                                 code: firstCode, ms: ms0 + (Perf.nowMs() - t1),
                                 altUsed: false, ok: false, err: err)
    }

    /// R7-P5 头像自检: 库内 3 个 avatar_url + 3 个 cover, 逐个 GET,
    /// 输出 host 维度结果与是否走了备用图床（不含完整 URL）
    static func runAvatarCheck() async -> [AvatarProbeResult] {
        var out: [AvatarProbeResult] = []
        for a in await sampleAvatars() {
            out.append(await probeImage(a, isAvatar: true))
        }
        for c in await sampleAppCovers(3) {
            out.append(await probeImage(c, isAvatar: false))
        }
        return out
    }

    /// "app"/"web"/"sht"/"ext" → CdnKind（自检取样 kind 名与熔断桶名一致）
    private static func cdnKind(_ kind: String) -> CdnKind {
        switch kind {
        case "web": return .jdbWeb
        case "sht": return .sht
        case "ext": return .external
        default: return .jdbApp
        }
    }

    /// app 样例: 索引序取 30 条 (走 idx_release), 内存挑第一个 /covers/
    /// （img.selftest.movie; 异常 → 内置兜底样例）
    private static func sampleAppCover() async -> String {
        do {
            let rows = try await Db.query(
                "jdb", "SELECT id, cover_url FROM movies ORDER BY release_date DESC LIMIT 30")
            return rows.map { $0.s("cover_url") }
                .first { $0.contains("/covers/") } ?? FALLBACK_APP_URL
        } catch {
            return FALLBACK_APP_URL
        }
    }

    /// 98t 样例: PK 序取 20 条, 挑第一个 http 开头（img.selftest.thread; 异常 → nil）
    private static func sampleShtImage() async -> String? {
        do {
            let ti = await Db.tableOf("sht", "thread_images")
            let rows = try await Db.query(
                "sht", "SELECT tid, url FROM \(ti) ORDER BY tid DESC LIMIT 20")
            return rows.map { $0.s("url") }.first { $0.hasPrefix("http") }
        } catch {
            return nil
        }
    }

    /// 外链样例: 最近 5 篇正文抽第一个非 jdb 图床 host 的 <img src>
    /// （img.selftest.article; 异常 → nil）
    private static func sampleExternal() async -> String? {
        do {
            let rows = try await Db.query(
                "jdb", "SELECT content_html FROM articles ORDER BY released_at DESC LIMIT 5")
            for r in rows {
                let html = r.s("content_html")
                if html.isEmpty { continue }
                let ns = html as NSString
                var found: String?
                EXT_IMG_RE.enumerateMatches(
                    in: html, options: [],
                    range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                    guard let m, m.numberOfRanges > 1,
                          m.range(at: 1).location != NSNotFound,
                          let rg = Range(m.range(at: 1), in: html) else { return }
                    let u = String(html[rg])
                    let low = u.lowercased()
                    if low.hasPrefix("http")
                        && !low.contains("spfcas") && !low.contains("jdbstatic") {
                        found = u
                        stop.pointee = true
                    }
                }
                if let found { return found }
            }
            return nil
        } catch {
            return nil
        }
    }
}
