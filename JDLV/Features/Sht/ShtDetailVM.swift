import Foundation
import UIKit
import JDLVCore

//
//  ShtDetailVM.swift —— 帖子详情 VM（09 D 节 ShtDetailScreen + D2/D3 契约）。
//
//  - viewModel key = "sht_$tid"（iOS 侧一页一实例对位）；离开页面 release() 清空整行数据。
//  - 数据装载 Q.shtThread：主行 = d["thread"] + 附属 magnets（hash/name/size/first_seen/link，
//    link 空时 Q 层已拼 magnet:?xt=urn:btih:<hash>）/ ed2k / images / videos /
//    blocks（article JSON 键 t/i/b/c/al/sz）/ words = article_words。
//  - 失败 → error = ErrText.of(e)（探活/影子兜底在 Q.shtThread 内完成）。
//  - d == nil（远程无此行）→ EmptyBox「远程库未收录该帖」。
//  - 加载成功后 historyMark("sht", tid, title) 写历史（read 初值 historyIs("sht", tid)）。
//  - 收藏：favToggle("sht", tid, title) → Toast「已收藏」/「已取消收藏」。
//  - 复制 Toast（D6 逐字）：「已复制磁力链接」/「已复制 ED2K」/「已复制视频直链」。
//

// MARK: - 详情数据模型（D3/D4 解析结果）

/// 磁力行（D6：卡片主行 link、次行 name/files_count、角标 fmtSize(size)）
struct ShtMagnet: Equatable {
    let hash: String
    let name: String
    let size: String
    let filesCount: Int64
    let link: String
    /// 空 link 回落 magnet:?xt=urn:btih:<hash>（Q 层已拼，此处再兜底一次）
    var displayLink: String {
        link.isEmpty ? "magnet:?xt=urn:btih:" + hash : link
    }
}

/// ED2K 行
struct ShtEd2k: Equatable {
    let url: String
    let name: String
    let size: String
}

/// 帖子详情解析结果（D4 分类判定与 D5 显示条件）
struct ShtThreadData: Equatable {
    let tid: String
    let title: String
    let boardName: String
    let postDate: String
    let catName: String
    let words: Int64
    var magnets: [ShtMagnet] = []
    var ed2k: [ShtEd2k] = []
    var images: [String] = []
    var videos: [String] = []
    var blocks: [ReaderBlock] = []

    /// 元信息行（D4）：board_name 与 post_date 非空项 joinToString(" · ")
    var metaLine: String {
        [boardName, postDate].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 分类判定（D4）：isImagePost = (cat == "自拍图片区") && images 非空
    var isImagePost: Bool { catName == "自拍图片区" && !images.isEmpty }
    /// isLiterature = (cat == "小说文学区") || blocks 非空
    var isLiterature: Bool { catName == "小说文学区" || !blocks.isEmpty }

    /// 正文显示条件（D5 三分支）：isLiterature && (cat=="小说文学区" || isImagePost ||
    /// (mags 空 && images 空)) → ReaderBody；其余普通渲染
    var useReaderBody: Bool {
        isLiterature && (catName == "小说文学区" || isImagePost || (magnets.isEmpty && images.isEmpty))
    }

    /// 空信息兜底（D8）：磁力、图片、视频、ED2K 全空且非文学帖
    var needsEmptyFallback: Bool {
        magnets.isEmpty && images.isEmpty && videos.isEmpty && ed2k.isEmpty && !isLiterature
    }

    // MARK: 解析（Q.shtThread 返回 [String: Any]；R3 问题 10 多形态解码）

    static func parse(_ d: [String: Any], tid: String) -> ShtThreadData {
        var out = ShtThreadData(
            tid: tid,
            title: decodeEntities(str(d, "title")),
            boardName: decodeEntities(str(d, "board_name")),
            postDate: str(d, "post_date"),
            catName: str(d, "cat_name"),
            words: int64(d, "words") ?? int64(d, "article_words") ?? 0)
        for m in parseMagnets(d["magnets"]) {
            out.magnets.append(m)
        }
        for e in d["ed2k"] as? [[String: Any]] ?? [] {
            out.ed2k.append(ShtEd2k(
                url: str(e, "url"), name: str(e, "name"), size: str(e, "size")))
        }
        out.images = parseImageUrls(d["images"])
        out.videos = (d["videos"] as? [Any])?.compactMap { $0 as? String } ?? []
        out.blocks = parseBlocks(d["blocks"], article: d["article"])
        return out
    }

    // MARK: 多形态解析（R3 问题 10）

    /// magnets：[[String:Any]]（hash/name/size/link）或 [String]（裸 magnet 链接）
    private static func parseMagnets(_ v: Any?) -> [ShtMagnet] {
        if let arr = v as? [[String: Any]] {
            return arr.map { m in
                ShtMagnet(
                    hash: str(m, "hash"), name: str(m, "name"), size: str(m, "size"),
                    filesCount: int64(m, "files_count") ?? 0, link: str(m, "link"))
            }
        }
        if let arr = v as? [Any] {
            return arr.compactMap { item -> ShtMagnet? in
                if let s = item as? String, !s.isEmpty {
                    let hash = s.contains("urn:btih:")
                        ? String(s.split(separator: ":").last ?? "") : ""
                    return ShtMagnet(hash: hash, name: "", size: "", filesCount: 0, link: s)
                }
                if let m = item as? [String: Any] {
                    return ShtMagnet(
                        hash: str(m, "hash"), name: str(m, "name"), size: str(m, "size"),
                        filesCount: int64(m, "files_count") ?? 0, link: str(m, "link"))
                }
                return nil
            }
        }
        return []
    }

    /// images：[String] 或 [[String:Any]]（url/src/image 三键名兼容）
    private static func parseImageUrls(_ v: Any?) -> [String] {
        guard let arr = v as? [Any] else { return [] }
        return arr.compactMap { item -> String? in
            if let s = item as? String { return decodeEntities(s) }
            if let m = item as? [String: Any] {
                for k in ["url", "src", "image"] {
                    if let s = m[k] as? String, !s.isEmpty { return decodeEntities(s) }
                }
            }
            return nil
        }
    }

    /// blocks：[[String:Any]] / JSON String / [String]（纯段落）；
    /// 全空且 article 为纯文本 → 按空行分段。HTML entity 解码。
    private static func parseBlocks(_ v: Any?, article: Any?) -> [ReaderBlock] {
        var blocks: [ReaderBlock] = []
        if let arr = v as? [[String: Any]] {
            blocks = arr.map { b in
                ReaderBlock(
                    t: decodeEntities(str(b, "t")).isEmpty ? nil : decodeEntities(str(b, "t")),
                    i: str(b, "i").isEmpty ? nil : str(b, "i"),
                    b: str(b, "b").isEmpty ? nil : str(b, "b"),
                    c: str(b, "c").isEmpty ? nil : str(b, "c"),
                    al: str(b, "al").isEmpty ? nil : str(b, "al"),
                    sz: Double(int64(b, "sz") ?? 0))
            }
        } else if let json = v as? String,
                  json.drop(while: { $0.isWhitespace }).first == "[" {
            if let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [[String: Any]] {
                blocks = parseBlocks(arr, article: nil)
            }
        } else if let arr = v as? [Any], !arr.isEmpty {
            // [String] 纯段落形态
            blocks = arr.compactMap { item -> ReaderBlock? in
                if let s = item as? String, !s.isEmpty {
                    return ReaderBlock(t: decodeEntities(s), i: nil, b: nil, c: nil,
                                       al: nil, sz: nil)
                }
                if let m = item as? [String: Any] {
                    let t = decodeEntities(str(m, "t"))
                    let i = str(m, "i")
                    if t.isEmpty && i.isEmpty { return nil }
                    return ReaderBlock(
                        t: t.isEmpty ? nil : t, i: i.isEmpty ? nil : i,
                        b: str(m, "b").isEmpty ? nil : str(m, "b"),
                        c: str(m, "c").isEmpty ? nil : str(m, "c"),
                        al: str(m, "al").isEmpty ? nil : str(m, "al"),
                        sz: Double(int64(m, "sz") ?? 0))
                }
                return nil
            }
        }
        if blocks.isEmpty, let text = article as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 纯文本 article：按空行分段
            blocks = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ReaderBlock(t: decodeEntities($0), i: nil, b: nil, c: nil,
                                   al: nil, sz: nil) }
        }
        return blocks
    }

    /// HTML entity 解码（&amp; &lt; &gt; &quot; &#39; &nbsp;）
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        // &amp; 必须最后替换（先解其他实体，防止 "&amp;lt;" 被双重解码为 "<"）
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&#39;", with: "'")
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    private static func str(_ d: [String: Any], _ k: String) -> String {
        switch d[k] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let i as Int64: return String(i)
        case let i as Int: return String(i)
        case let f as Double: return String(f)
        default: return ""
        }
    }

    private static func int64(_ d: [String: Any], _ k: String) -> Int64? {
        switch d[k] {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as Double: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }
}

// MARK: - ShtDetailVM

@MainActor
final class ShtDetailVM: ObservableObject {

    // MARK: 依赖（可注入）

    let source: ShtDataSource
    var marks: ShtMarkSource
    var onToast: (String) -> Void

    // MARK: 状态（D2）

    @Published var loading = false
    @Published var error: String? = nil
    @Published var d: ShtThreadData? = nil
    @Published var read = false
    @Published var fav = false

    private var reqId = 0

    init(
        tid: String = "",
        source: ShtDataSource? = nil,
        marks: ShtMarkSource? = nil,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoShtDataSource() : QShtDataSource())
        #else
        self.source = source ?? QShtDataSource()
        #endif
        self.marks = marks ?? ShtMarkSource.empty()
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    // MARK: 数据装载（D3）

    /// load：loading → source.shtThread(tid) → 解析；成功写历史（D2）；
    /// nil（远程无此行）→ d 保持 nil（页面 EmptyBox「远程库未收录该帖」）
    func load(_ tid: String) async {
        reqId += 1
        let rid = reqId
        loading = true
        error = nil
        do {
            let raw = try await source.shtThread(tid: tid)
            guard rid == reqId else { return }
            loading = false
            guard let raw else { return }   // d == nil → 空态
            let data = ShtThreadData.parse(raw, tid: tid)
            d = data
            read = marks.historyIs(tid)
            fav = marks.favIs(tid)
            // 加载成功后写历史（D2：historyMark("sht", tid, title)）
            marks.historyMark(tid, data.title)
            read = true
        } catch {
            guard rid == reqId else { return }
            loading = false
            self.error = ErrText.of(error)
        }
    }

    /// 收藏切换（D2：favToggle → Toast「已收藏」/「已取消收藏」）
    func toggleFav(_ tid: String) {
        let title = d?.title ?? ""
        let now = marks.favToggle(tid, title)
        fav = now
        onToast(now ? "已收藏" : "已取消收藏")
    }

    /// 离开页面 release()：清空整行数据（D2）
    func release() {
        reqId += 1
        d = nil
        error = nil
        loading = false
        read = false
        fav = false
    }

    // MARK: 复制（D6：点整卡复制 + Toast 逐字）

    func copyMagnet(_ m: ShtMagnet) {
        UIPasteboard.general.string = m.displayLink
        onToast("已复制磁力链接")
    }

    func copyEd2k(_ e: ShtEd2k) {
        UIPasteboard.general.string = e.url
        onToast("已复制 ED2K")
    }

    func copyVideo(_ url: String) {
        UIPasteboard.general.string = url
        onToast("已复制视频直链")
    }
}
