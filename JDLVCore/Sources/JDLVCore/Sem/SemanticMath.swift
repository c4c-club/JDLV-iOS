import Foundation

//
//  SemanticMath —— 语义搜索纯数值工具（P11）。
//  对齐 Android data/Semantic.kt score()（docs/_extract/12_img_sem.md §7.4）
//  与抓取端 core/semsearch.py 的 int8 语义（emb_to_int8 = round(v * 127)）。
//
//  对齐铁律（12 §7.1）：查询向量 L2 归一化（下限 1e-9），候选向量 int8 还原
//  v = b / 127.0f（b 为**有符号字节**），点积即余弦相似度；维度不一致一律 -inf
//  （★ NA-08：旧版 minOf(q.size, blob.size) 混算 384/512 维产生无意义相似度）。
//  纯 Foundation，无 ORT / 无数据库依赖。
//

public enum SemanticMath {

    /// 点积。维度不符返回 -Float.infinity（对齐 Android score 的 NA-08 校验）。
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        if a.count != b.count { return -Float.infinity }
        var s: Float = 0
        for i in a.indices {
            s += a[i] * b[i]
        }
        return s
    }

    /// L2 归一化（新数组返回）。norm 下限 1e-9f（对齐 Android embed 的 norm floor）。
    /// 空数组原样返回。
    public static func l2normalize(_ v: [Float]) -> [Float] {
        if v.isEmpty { return v }
        var sum: Float = 0
        for x in v {
            sum += x * x
        }
        let norm = sum.squareRoot() // Android: sqrt(sum).coerceAtLeast(1e-9f)
        let n = norm < 1e-9 ? 1e-9 : norm
        return v.map { $0 / n }
    }

    /// int8 向量解码：每字节 b = Float(Int8(bitPattern: byte)) / 127.0
    /// （Android blob[i] 是 signed byte：blob[i].toFloat() / 127.0f）。
    /// Data 为空 → 空数组。
    public static func int8Decode(_ bytes: Data) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            out.append(Float(Int8(bitPattern: byte)) / 127.0)
        }
        return out
    }

    /// 余弦打分（Android Semantic.score 逐字口径）：
    /// blob 为空或维度 ≠ 查询维度 → -inf；否则 dot(query, int8Decode(blob))。
    /// 乘加顺序与 Android 一致（先 b/127 再乘加），同输入同结果（Float 位级一致）。
    public static func score(query: [Float], blob: Data) -> Float {
        if blob.isEmpty || blob.count != query.count {
            return -Float.infinity
        }
        return dot(query, int8Decode(blob))
    }
}
