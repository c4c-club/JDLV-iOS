import Foundation

//
//  Fmt.swift —— 格式化工具（07 B2：fmtSize / fmtTime；评分星标格式）。
//
//  - fmtSize(v)：纯数字按 MB；>=1024 → `%.2f` 除以 1024 后去尾零（'0' 与 '.'）+ " GB"；
//    否则 "N MB"；含字母原样返回（桌面 _fmt_size 语义）。
//  - fmtTime(ts)：HH:mm（本地时区），ts<=0 返回空串。
//  - score(v)：★ {score} 用的数字串（最多两位小数、去尾零；v<=0 空串不渲染）。
//  - ActorCard 均分固定 "%.2f"（07 B15，见 AppCopy.actorMetaLine）。
//
enum Fmt {

    static func fmtSize(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespaces)
        guard let n = Double(t) else { return v }        // 含字母原样返回
        if n >= 1024 {
            var s = String(format: "%.2f", n / 1024)
            while s.hasSuffix("0") { s.removeLast() }    // trimEnd('0')
            if s.hasSuffix(".") { s.removeLast() }       // trimEnd('.')
            return s + " GB"
        }
        return "\(Int64(n)) MB"
    }

    static func fmtTime(_ ts: Int64) -> String {
        guard ts > 0 else { return "" }
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    /// "★ {score}" 数字部分（4.5 / 4 / 4.55；去尾零）
    static func score(_ v: Double) -> String {
        guard v > 0 else { return "" }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
