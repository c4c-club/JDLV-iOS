import Foundation

//
//  BertTokenizer —— 语义模型分词器（P11，纯 Foundation）。
//
//  ★ 实况与规划差异（重要）: models/minilm/tokenizer.json 实际是 XLM-R 系
//  （paraphrase-multilingual-MiniLM-L12-v2, 250002 词, Unigram/sentencepiece）:
//    normalizer    = Precompiled（spm precompiled_charsmap: Darts DoubleArray + 改写池）
//    pre_tokenizer = Sequence[WhitespaceSplit, Metaspace(▁, add_prefix_space=true)]
//    model         = Unigram（Viterbi 最优路径, unk_id=3, fuse_unk）
//    post_processor= TemplateProcessing <s> A </s>（SpecialToken id 0 / 2）
//    truncation    = Right / max_length=128 / LongestFirst
//  而非任务初稿假设的 BertNormalizer/WordPiece/[CLS]…[SEP]。本实现按真实文件移植，
//  并与 HuggingFace tokenizers 0.22.2 逐 id 对齐（golden 100% 相等硬门禁，见
//  TokenizerTests + tools/gen_tokenizer_golden.py）。对齐铁律: docs/_extract/12_img_sem.md
//  §7.1 —— 任何一环节不一致 → 向量空间不同 → 搜索结果全错。
//
//  算法移植来源（v0.22.2）:
//   - spm_precompiled lib.rs: DoubleArray.common_prefix_search / transform /
//     normalize_string（grapheme <6B 整簇查表, 否则逐 Unicode scalar）
//   - tokenizers pre_tokenizers/whitespace.rs: WhitespaceSplit =
//     split(char::is_whitespace, Removed)（White_Space 性质逐字集合）
//   - tokenizers pre_tokenizers/metaspace.rs: Metaspace Always = 空格→▁ + 前置▁ +
//     split(▁, MergedWithNext)
//   - tokenizers models/unigram/model.rs: encode_optimized（UTF-8 字节位 DP +
//     unk_score = min_score - 10.0 + 回溯 fuse_unk → 串映射 id, 缺失补 unk）
//   - tokenizers tokenizer/mod.rs post_process: 先截断（max_length - n_added）
//     再加 <s>…</s> 特殊 token（single 序列无 padding, mask 全 1）
//   - added_tokens: special token 在**原文**上最长匹配切出（不经归一化）,
//     其余片段各自独立归一化/预切分/编码
//
//  Android 对应: DJL HuggingFaceTokenizer(同 tokenizer.json) → ids 一致;
//  embed 侧 MAX_LEN=64 手动截断在 OnnxEmbedder 做（本类保持 HF encode 语义）。
//

public struct BertTokenizer: Sendable {

    public enum TokenizerError: Error, CustomStringConvertible {
        case badJSON(String)
        case badCharsmap
        case unsupportedNormalizer(String)
        case unsupportedPreTokenizer(String)
        case unsupportedModel(String)
        case unsupportedPostProcessor(String)
        case unsupportedTruncation(String)
        case missingSpecialToken(String)

        public var description: String {
            switch self {
            case .badJSON(let m): return "tokenizer.json 解析失败: \(m)"
            case .badCharsmap: return "precompiled_charsmap 非法"
            case .unsupportedNormalizer(let t): return "不支持的 normalizer: \(t)"
            case .unsupportedPreTokenizer(let t): return "不支持的 pre_tokenizer: \(t)"
            case .unsupportedModel(let t): return "不支持的 model: \(t)（仅支持 Unigram）"
            case .unsupportedPostProcessor(let t): return "不支持的 post_processor: \(t)"
            case .unsupportedTruncation(let t): return "不支持的 truncation: \(t)"
            case .missingSpecialToken(let t): return "特殊 token 不在词表: \(t)"
            }
        }
    }

    // MARK: - 状态

    /// Darts DoubleArray（precompiled_charsmap 前段, u32 LE 单元）
    private let trie: [UInt32]
    /// 改写池（charsmap 后段: UTF-8 串 + \0 终止）
    private let pool: [UInt8]

    /// Unigram 词表（下标 = id）
    private let vocabPieces: [[UInt8]]
    private let vocabScores: [Double]
    /// 词表字节键（byte-exact 匹配, 与 Rust trie 字节语义一致）
    private let vocabBytes: [[UInt8]: Int]
    private let unkId: Int
    private let minScore: Double
    private let maxPieceBytes: Int

    /// special added tokens（原文最长匹配切出; 按 scalar 数降序）
    private let addedTokens: [([Unicode.Scalar], Int)]

    /// TemplateProcessing: A 前/后的 special token id（如 <s>…</s>）
    private let prefixIds: [Int]
    private let suffixIds: [Int]

    /// truncation（来自 tokenizer.json; single 序列）
    private let truncMaxLength: Int?
    private let truncRight: Bool

    /// 预切分开关
    private let hasWhitespaceSplit: Bool
    /// Metaspace 替换符（nil = 无 Metaspace）; prependScheme Always
    private let metaspaceRep: Unicode.Scalar?

    // MARK: - 解析

    public init(tokenizerJSON: Data) throws {
        let root = try JSONSerialization.jsonObject(with: tokenizerJSON, options: [])
        guard let obj = root as? [String: Any] else {
            throw TokenizerError.badJSON("root 非对象")
        }

        // ---- model: Unigram ----
        guard let model = obj["model"] as? [String: Any] else {
            throw TokenizerError.badJSON("缺 model")
        }
        guard let modelType = model["type"] as? String else {
            throw TokenizerError.badJSON("model.type 缺失")
        }
        guard modelType == "Unigram" else {
            throw TokenizerError.unsupportedModel(modelType)
        }
        guard let vocabRaw = model["vocab"] as? [[Any]] else {
            throw TokenizerError.badJSON("model.vocab 应为 [piece, score] 对列表")
        }
        let unk = (model["unk_id"] as? NSNumber).map { $0.intValue } ?? 0

        var pieces: [[UInt8]] = []
        var scores: [Double] = []
        var byteId: [[UInt8]: Int] = [:]
        var minScore = Double.infinity
        var maxPieceBytes = 0
        pieces.reserveCapacity(vocabRaw.count)
        scores.reserveCapacity(vocabRaw.count)
        for (i, pair) in vocabRaw.enumerated() {
            guard pair.count == 2, let piece = pair[0] as? String, let score = pair[1] as? Double else {
                throw TokenizerError.badJSON("vocab[\(i)] 应为 [String, Double]")
            }
            let bytes = Array(piece.utf8)
            byteId[bytes] = i
            pieces.append(bytes)
            scores.append(score)
            if score < minScore { minScore = score }
            if bytes.count > maxPieceBytes { maxPieceBytes = bytes.count }
        }
        guard unk < pieces.count else { throw TokenizerError.badJSON("unk_id 越界") }

        // ---- normalizer: Precompiled ----
        var trie: [UInt32] = []
        var pool: [UInt8] = []
        if let normalizer = obj["normalizer"] as? [String: Any] {
            let ntype = normalizer["type"] as? String
            if ntype == "Precompiled" {
                guard let b64 = normalizer["precompiled_charsmap"] as? String,
                      let blob = Data(base64Encoded: b64), blob.count > 4 else {
                    throw TokenizerError.badCharsmap
                }
                let bytes = [UInt8](blob)
                let trieSize = Int(bytes[0]) | (Int(bytes[1]) << 8)
                    | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
                guard trieSize % 4 == 0, 4 + trieSize <= bytes.count else {
                    throw TokenizerError.badCharsmap
                }
                trie.reserveCapacity(trieSize / 4)
                var off = 4
                while off < 4 + trieSize {
                    let u = UInt32(bytes[off]) | (UInt32(bytes[off + 1]) << 8)
                        | (UInt32(bytes[off + 2]) << 16) | (UInt32(bytes[off + 3]) << 24)
                    trie.append(u)
                    off += 4
                }
                pool = Array(bytes[(4 + trieSize)...])
            } else if ntype != nil && ntype != "null" {
                throw TokenizerError.unsupportedNormalizer(ntype ?? "?")
            }
        }

        // ---- added_tokens（special 切分, 原文最长匹配）----
        var added: [([Unicode.Scalar], Int)] = []
        var addedById: [String: Int] = [:]
        if let arr = obj["added_tokens"] as? [[String: Any]] {
            for t in arr {
                guard let content = t["content"] as? String else { continue }
                let id = (t["id"] as? NSNumber).map { $0.intValue } ?? -1
                addedById[content] = id
                added.append((Array(content.unicodeScalars), id))
            }
        }
        added.sort { $0.0.count > $1.0.count }

        // ---- pre_tokenizer: Sequence[WhitespaceSplit, Metaspace] ----
        var hasWsSplit = false
        var metaspaceRep: Unicode.Scalar? = nil
        if let pt = obj["pre_tokenizer"] as? [String: Any] {
            let list: [[String: Any]]
            if (pt["type"] as? String) == "Sequence" {
                guard let l = pt["pretokenizers"] as? [[String: Any]] else {
                    throw TokenizerError.badJSON("pre_tokenizer.pretokenizers 非列表")
                }
                list = l
            } else {
                list = [pt]
            }
            for item in list {
                switch item["type"] as? String {
                case "WhitespaceSplit":
                    hasWsSplit = true
                case "Metaspace":
                    guard let repStr = item["replacement"] as? String,
                          let rep = repStr.unicodeScalars.first else {
                        throw TokenizerError.badJSON("Metaspace.replacement 非法")
                    }
                    // 反序列化: add_prefix_space=false ⇒ Never; 其余（缺省）⇒ Always
                    var always = true
                    if let aps = item["add_prefix_space"] as? Bool, !aps { always = false }
                    if let scheme = item["prepend_scheme"] as? String {
                        switch scheme {
                        case "always": always = true
                        case "never": always = false
                        default: throw TokenizerError.unsupportedPreTokenizer("Metaspace.\(scheme)")
                        }
                    }
                    if always == false {
                        throw TokenizerError.unsupportedPreTokenizer("Metaspace prepend=never")
                    }
                    if let split = item["split"] as? Bool, !split {
                        throw TokenizerError.unsupportedPreTokenizer("Metaspace split=false")
                    }
                    metaspaceRep = rep
                case nil:
                    break
                case let other?:
                    throw TokenizerError.unsupportedPreTokenizer(other)
                }
            }
        }

        // ---- post_processor: TemplateProcessing ----
        var prefixIds: [Int] = []
        var suffixIds: [Int] = []
        if let pp = obj["post_processor"] as? [String: Any] {
            guard (pp["type"] as? String) == "TemplateProcessing" else {
                throw TokenizerError.unsupportedPostProcessor(pp["type"] as? String ?? "?")
            }
            guard let single = pp["single"] as? [[String: Any]] else {
                throw TokenizerError.badJSON("post_processor.single 非列表")
            }
            var seenA = false
            for item in single {
                if let st = item["SpecialToken"] as? [String: Any] {
                    guard let tid = st["id"] as? String else {
                        throw TokenizerError.badJSON("SpecialToken.id 缺失")
                    }
                    guard let sid = addedById[tid] ?? byteId[Array(tid.utf8)] else {
                        throw TokenizerError.missingSpecialToken(tid)
                    }
                    if seenA { suffixIds.append(sid) } else { prefixIds.append(sid) }
                } else if item["Sequence"] != nil {
                    seenA = true
                }
            }
        }

        // ---- truncation ----
        var truncMax: Int? = nil
        var truncRight = true
        if let tr = obj["truncation"] as? [String: Any] {
            let dir = tr["direction"] as? String ?? "Right"
            let strategy = tr["strategy"] as? String ?? "LongestFirst"
            guard dir == "Right" || dir == "Left" else {
                throw TokenizerError.unsupportedTruncation("direction=\(dir)")
            }
            guard strategy == "LongestFirst" else {
                throw TokenizerError.unsupportedTruncation("strategy=\(strategy)")
            }
            truncMax = (tr["max_length"] as? NSNumber).map { $0.intValue }
            truncRight = (dir == "Right")
        }

        self.trie = trie
        self.pool = pool
        self.vocabPieces = pieces
        self.vocabScores = scores
        self.vocabBytes = byteId
        self.unkId = unk
        self.minScore = minScore
        self.maxPieceBytes = maxPieceBytes
        self.addedTokens = added
        self.prefixIds = prefixIds
        self.suffixIds = suffixIds
        self.truncMaxLength = truncMax
        self.truncRight = truncRight
        self.hasWhitespaceSplit = hasWsSplit
        self.metaspaceRep = metaspaceRep
    }

    // MARK: - encode（对齐 HF Tokenizer.encode(text, add_special_tokens: true)）

    /// 返回 (ids, attention_mask)。单序列无 padding → mask 全 1。
    public func encode(_ text: String) -> (ids: [Int], mask: [Int]) {
        var ids: [Int] = []

        // ① AddedVocabulary: special token 在原文（未归一化）上最长匹配切出
        let scalars = Array(text.unicodeScalars)
        var i = 0
        var segStart = 0
        func flushSegment(_ upTo: Int) {
            guard segStart < upTo else { return }
            let seg = String(String.UnicodeScalarView(scalars[segStart..<upTo]))
            tokenizeSegment(seg, into: &ids)
        }
        while i < scalars.count {
            var hit: ([Unicode.Scalar], Int)? = nil
            for cand in addedTokens {
                let n = cand.0.count
                if i + n <= scalars.count {
                    var ok = true
                    for j in 0..<n where cand.0[j] != scalars[i + j] { ok = false; break }
                    if ok { hit = cand; break }
                }
            }
            if let h = hit {
                flushSegment(i)
                ids.append(h.1)
                i += h.0.count
                segStart = i
            } else {
                i += 1
            }
        }
        flushSegment(scalars.count)

        // ② 截断（post_process: 先截断, max_length 扣掉模板 special token 数, 再拼特殊 token）
        let nAdded = prefixIds.count + suffixIds.count
        if let maxLen = truncMaxLength {
            let keep = max(maxLen - nAdded, 0)
            if ids.count > keep {
                ids = truncRight ? Array(ids.prefix(keep)) : Array(ids.suffix(keep))
            }
        }
        var final = prefixIds
        final.append(contentsOf: ids)
        final.append(contentsOf: suffixIds)
        let mask = Array(repeating: 1, count: final.count)
        return (final, mask)
    }

    /// 单片段: 归一化 → WhitespaceSplit(Removed) → Metaspace(Always) → Unigram。
    private func tokenizeSegment(_ seg: String, into ids: inout [Int]) {
        let normalized = normalizeString(seg)
        var pieces: [String] = hasWhitespaceSplit ? whitespaceSplit(normalized) : [normalized]
        if let rep = metaspaceRep {
            pieces = metaspace(pieces, rep: rep)
        }
        for p in pieces {
            unigramTokenize(p, into: &ids)
        }
    }

    // MARK: - Precompiled normalizer（spm_precompiled 移植）

    /// Darts DoubleArray common_prefix_search（字节键; 返回升序匹配的池内偏移）。
    private func commonPrefixSearch(_ key: [UInt8]) -> [Int] {
        var results: [Int] = []
        if trie.isEmpty { return results }
        var nodePos = 0
        var unit = trie[0]
        nodePos ^= Self.dartsOffset(unit)
        for c in key {
            if c == 0 { break }
            nodePos ^= Int(c)
            if nodePos < 0 || nodePos >= trie.count { return results }
            unit = trie[nodePos]
            if Self.dartsLabel(unit) != UInt32(c) { return results }
            nodePos ^= Self.dartsOffset(unit)
            if nodePos < 0 || nodePos >= trie.count { return results }
            if Self.dartsHasLeaf(unit) {
                results.append(Self.dartsValue(trie[nodePos]))
            }
        }
        return results
    }

    /// 查表改写（取**首个**匹配 = results[0], 与 spm_precompiled 一致）。
    private func transform(_ chunk: [UInt8]) -> String? {
        let results = commonPrefixSearch(chunk)
        guard let index = results.first, index <= pool.count else { return nil }
        var i = index
        while i < pool.count {
            if pool[i] == 0 { break }
            i += 1
        }
        return String(decoding: pool[index..<i], as: UTF8.self)
    }

    /// normalize_string: grapheme <6B 整簇查表（命中即整簇替换）, 否则逐 Unicode scalar。
    private func normalizeString(_ original: String) -> String {
        var out = String.UnicodeScalarView()
        for g in original {
            let gb = Array(g.utf8)
            if gb.count < 6 {
                if let norm = transform(gb) {
                    out.append(contentsOf: norm.unicodeScalars)
                    continue
                }
            }
            for sc in g.unicodeScalars {
                if let norm = transform(Array(sc.utf8)) {
                    out.append(contentsOf: norm.unicodeScalars)
                } else {
                    out.append(sc)
                }
            }
        }
        return String(out)
    }

    // darts.h 位运算（u32 单元）
    private static func dartsHasLeaf(_ u: UInt32) -> Bool { (u >> 8) & 1 == 1 }
    private static func dartsValue(_ u: UInt32) -> Int { Int(u & 0x7FFF_FFFF) }
    private static func dartsLabel(_ u: UInt32) -> UInt32 { u & 0x8000_00FF }
    private static func dartsOffset(_ u: UInt32) -> Int {
        Int((u >> 10) << ((u & 0x200) >> 6))
    }

    // MARK: - WhitespaceSplit（split(char::is_whitespace, Removed)）

    /// Rust char::is_whitespace = Unicode White_Space 性质（逐字集合, 不随 Unicode 版本漂移）。
    private static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// 删去全部 White_Space 字符, 保留非空白连续段（Removed; 空段由调用方丢弃）。
    private func whitespaceSplit(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            if Self.isWhitespace(sc) {
                if !cur.isEmpty {
                    out.append(String(cur))
                    cur = String.UnicodeScalarView()
                }
            } else {
                cur.append(sc)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    // MARK: - Metaspace（Always: 空格→▁ + 前置▁ + split(▁, MergedWithNext)）

    private func metaspace(_ pieces: [String], rep: Unicode.Scalar) -> [String] {
        var out: [String] = []
        for piece in pieces {
            var arr = Array(piece.unicodeScalars)
            for k in arr.indices where arr[k] == " " { arr[k] = rep }
            if arr.first != rep { arr.insert(rep, at: 0) }
            // find_matches: 非 rep 连续段(F) + 单个 rep(T)
            var segs: [(Int, Int, Bool)] = []
            var start = 0
            for i in 0..<arr.count where arr[i] == rep {
                if start < i { segs.append((start, i, false)) }
                segs.append((i, i + 1, true))
                start = i + 1
            }
            if start < arr.count { segs.append((start, arr.count, false)) }
            // MergedWithNext: 从右向左折, 每个 rep 并入其右侧片段
            var acc: [(Int, Int)] = []
            var prev = false
            for (a, b, m) in segs.reversed() {
                if m && !prev {
                    if !acc.isEmpty {
                        acc[acc.count - 1].0 = a
                    } else {
                        acc.append((a, b))
                    }
                } else {
                    acc.append((a, b))
                }
                prev = m
            }
            for (a, b) in acc.reversed() {
                let piece2 = String(String.UnicodeScalarView(arr[a..<b]))
                if !piece2.isEmpty { out.append(piece2) }
            }
        }
        return out
    }

    // MARK: - Unigram（encode_optimized 移植: UTF-8 字节位 DP + 回溯 fuse_unk）

    private func unigramTokenize(_ s: String, into ids: inout [Int]) {
        let bytes = Array(s.utf8)
        let size = bytes.count
        if size == 0 { return }
        let unkScore = minScore - 10.0

        var bestScore = [Double](repeating: 0, count: size + 1)
        var bestStart = [Int?](repeating: nil, count: size + 1)
        var bestId = [Int](repeating: 0, count: size + 1)

        var startsAt = 0
        while startsAt < size {
            let tillHere = bestStart[startsAt] != nil ? bestScore[startsAt] : 0.0
            let lead = bytes[startsAt]
            let mblen: Int
            if lead < 0x80 { mblen = 1 } else if lead < 0xE0 { mblen = 2 }
            else if lead < 0xF0 { mblen = 3 } else { mblen = 4 }

            var hasSingleNode = false
            let upper = min(maxPieceBytes, size - startsAt)
            if upper > 0 {
                for len in 1...upper {
                    let end = startsAt + len
                    if let id = vocabBytes[Array(bytes[startsAt..<end])] {
                        let cand = vocabScores[id] + tillHere
                        if bestStart[end] == nil || cand > bestScore[end] {
                            bestScore[end] = cand
                            bestStart[end] = startsAt
                            bestId[end] = id
                        }
                        if !hasSingleNode && len == mblen { hasSingleNode = true }
                    }
                }
            }
            if !hasSingleNode {
                let end = startsAt + mblen
                let cand = unkScore + tillHere
                if bestStart[end] == nil || cand > bestScore[end] {
                    bestScore[end] = cand
                    bestStart[end] = startsAt
                    bestId[end] = unkId
                }
            }
            startsAt += mblen
        }

        // 回溯（fuse_unk: 连续 unk 片段合成一个字节段, 再映射 id）
        var results: [Range<Int>] = []
        var fused: [Range<Int>] = []
        var endsAt = size
        while endsAt > 0 {
            guard let sa = bestStart[endsAt] else { break }
            let range = sa..<endsAt
            if bestId[endsAt] == unkId {
                fused.append(range)
            } else {
                if !fused.isEmpty {
                    results.append(fused[fused.count - 1].lowerBound..<fused[0].upperBound)
                    fused.removeAll()
                }
                results.append(range)
            }
            endsAt = sa
        }
        if !fused.isEmpty {
            results.append(fused[fused.count - 1].lowerBound..<fused[0].upperBound)
        }
        results.reverse()
        for r in results {
            ids.append(vocabBytes[Array(bytes[r])] ?? unkId)
        }
    }
}
