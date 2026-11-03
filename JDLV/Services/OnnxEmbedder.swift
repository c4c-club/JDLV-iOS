import Foundation
import JDLVCore

//
//  OnnxEmbedder —— ORT 本地查询向量推理（P11, 仅 App target）。
//  对位 Android data/Semantic.kt（docs/_extract/12_img_sem.md §7, 逐条对齐）。
//
//  文件布局: <Application Support>/semantic/model.onnx + tokenizer.json
//  （Android ctx.filesDir/semantic/ 的 iOS 对应; 模型不随包分发, 用户在设置页导入,
//  未导入时语义搜索禁用 → 返回 nil, 调用方禁止静默降级）。
//
//  对齐铁律（§7.1）: ①分词 BertTokenizer(与 HF tokenizers 同源, ids 与 golden 100% 相等);
//  ②输入 int64 [1,n]; ③输出 mean pooling（跳过 mask=0, /mask.sum() 下限 1e-9）→ L2
//  （下限 1e-9）; ④候选 int8 还原 b/127.0 点积（SemanticMath.score）。dim=384。
//
//  加载状态机（§7.2）: isInstalled 只看文件; ensure 惰性加载; loadTried 旗标 ——
//  加载失败后不再重试（loadTried && session == nil → false）, 直到 install() 重置;
//  失败记 lastError 不抛给调用方; prepare = ensure。
//
//  推理（§7.3 逐条）: 空文本防御 " " 占位 → encode → n = min(ids, mask, MAX_LEN=64)
//  截断 → int64 [1,n] 张量 → input_ids/attention_mask 必喂, token_type_ids 仅当模型
//  声明才喂全 0（MiniLM 有, bge/e5/m3e 多数没有, 多喂报错）→ run → 输出 [1,384]
//  mean pooling + L2。NA-17: ObjC ORTValue/Result 由 ARC 释放（对位 Android finally
//  close —— iOS 绑定无手动 close API）。
//

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings

/// SemEmbedder 生产实现（ORT 推理）。
public final class OnnxEmbedder: SemEmbedder {

    public static let DIR = "semantic"
    public static let MODEL = "model.onnx"
    public static let TOK = "tokenizer.json"
    /// 等价 Python truncation(max_length=64)（Android 手动截断; tokenizer.json 的
    /// 128 截断在 BertTokenizer.encode 内已按 HF 语义生效）
    public static let MAX_LEN = 64
    /// 输出维度（与抓取端 emb_to_int8 候选向量同空间）
    public static let DIM = 384

    private let lock = NSLock()
    private var env: ORTEnv?
    private var session: ORTSession?
    private var tokenizer: BertTokenizer?
    private var loadTried = false
    /// 最近一次加载/推理失败原因（用户可见提示用）
    public private(set) var lastError: String?

    public init() {}

    // MARK: - 路径 / 安装态

    /// <Application Support>/semantic/
    public static func directory(create: Bool = false) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(DIR, isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func modelURL() -> URL { directory().appendingPathComponent(MODEL) }
    public static func tokenizerURL() -> URL { directory().appendingPathComponent(TOK) }

    /// 两个文件都存在且非空（不加载只看文件）
    public static func isInstalled() -> Bool {
        let m = (try? FileManager.default.attributesOfItem(atPath: modelURL().path))?[.size] as? Int
        let t = (try? FileManager.default.attributesOfItem(atPath: tokenizerURL().path))?[.size] as? Int
        return (m ?? 0) > 0 && (t ?? 0) > 0
    }

    /// 会话与分词器都已就绪
    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil && tokenizer != nil
    }

    /// 导入模型/分词器（设置页）: 覆盖式幂等拷贝 → 重置会话与 loadTried → ensure。
    /// 拷贝失败抛错（用户可见: "无法读取所选文件"）。
    public func install(model sourceModel: URL, tokenizer sourceTok: URL) throws {
        let fm = FileManager.default
        Self.directory(create: true)
        for (src, dst) in [(sourceModel, Self.modelURL()), (sourceTok, Self.tokenizerURL())] {
            guard fm.fileExists(atPath: src.path) else {
                throw NSError(domain: "OnnxEmbedder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取所选文件"])
            }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        lock.lock()
        session = nil
        tokenizer = nil
        loadTried = false
        lastError = nil
        lock.unlock()
        prepare()
    }

    // MARK: - 加载状态机

    /// 惰性加载; 失败后不再重试, 直到 install() 重置。返回是否就绪。
    @discardableResult
    public func prepare() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if session != nil && tokenizer != nil { return true }
        if loadTried { return false }
        loadTried = true
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let session = try ORTSession(env: env, modelPath: Self.modelURL().path, sessionOptions: nil)
            let tokData = try Data(contentsOf: Self.tokenizerURL())
            let tok = try BertTokenizer(tokenizerJSON: tokData)
            self.env = env
            self.session = session
            self.tokenizer = tok
            return true
        } catch {
            self.session = nil
            self.tokenizer = nil
            self.lastError = String(describing: error)
            return false
        }
    }

    // MARK: - embed（Android Semantic.embed 逐条对齐）

    /// 查询 → L2 归一化 384 维向量。未导入/未就绪/推理失败 → nil（调用方禁止静默降级）。
    public func embed(_ text: String) async -> [Float]? {
        // 防御: 未加载先惰性拉起（与 Android ensure 语义一致）
        if !isReady {
            guard prepare() else { return nil }
        }
        let t0 = Perf.begin("semantic.embed")
        // ① 空文本防御: blank → " "（空格占位再编码）
        let safe = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : text
        do {
            let (ids0, mask0) = try tokenize(safe)
            // ③ 截断: n = min(ids, mask, 64); int64
            let n = min(ids0.count, mask0.count, Self.MAX_LEN)
            guard n > 0 else { throw NSError(domain: "OnnxEmbedder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "分词结果为空"]) }
            let ids = Array(ids0.prefix(n).map { Int64($0) })
            let mask = Array(mask0.prefix(n).map { Int64($0) })

            lock.lock()
            let session = self.session
            var inputNames: [String] = []
            if let s = session, let names = try? s.inputNames() { inputNames = names }
            lock.unlock()
            guard let session = session else {
                lastError = lastError ?? "session 未就绪"
                Perf.end("semantic.embed", t0, "FAIL no-session")
                return nil
            }

            // ⑤/⑥ 张量: int64 [1,n]; token_type_ids 仅当模型声明才喂全 0
            var feed: [String: ORTValue] = [:]
            feed["input_ids"] = try Self.tensorInt64(ids, shape: [1, n])
            feed["attention_mask"] = try Self.tensorInt64(mask, shape: [1, n])
            if inputNames.contains("token_type_ids") {
                feed["token_type_ids"] = try Self.tensorInt64(
                    Array(repeating: 0, count: n), shape: [1, n])
            }

            // ⑦ run → [1, dim] 扁平 Float
            let outputs = try session.run(withInputs: feed,
                                          outputNames: Set([firstOutputName(session)]),
                                          runOptions: nil)
            guard let (_, outValue) = outputs.first else {
                throw NSError(domain: "OnnxEmbedder", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "输出为空"])
            }
            let data = try outValue.tensorData()
            let flat = data.withUnsafeBytes { raw -> [Float] in
                let p = raw.bindMemory(to: Float.self)
                return Array(p)
            }

            // ⑧ mean pooling（跳过 mask=0, /mask.sum() 下限 1e-9）
            // 防御: 输出必须为 [1, n, dim]（n*dim 扁平）; 对齐模型输出 token 级嵌入
            guard flat.count % n == 0, flat.count / n >= 1 else {
                throw NSError(domain: "OnnxEmbedder", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "输出维度非法: \(flat.count)/n=\(n)"])
            }
            let dim = flat.count / n
            var v = [Float](repeating: 0, count: dim)
            var msum: Float = 0
            for i in 0..<n where mask[i] != 0 {
                msum += 1
                let base = i * dim
                for k in 0..<dim {
                    v[k] += flat[base + k]
                }
            }
            msum = max(msum, 1e-9)
            for k in 0..<dim { v[k] /= msum }

            // ⑨ L2（下限 1e-9）
            let out = SemanticMath.l2normalize(v)
            Perf.end("semantic.embed", t0, "dim=\(dim) len=\(n)")
            return out
        } catch {
            lastError = String(describing: error)
            Perf.end("semantic.embed", t0, "FAIL \(type(of: error))")
            return nil
        }
    }

    // MARK: - 私有

    private func tokenize(_ text: String) throws -> (ids: [Int], mask: [Int]) {
        lock.lock(); defer { lock.unlock() }
        guard let tok = tokenizer else {
            throw NSError(domain: "OnnxEmbedder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "tokenizer 未加载"])
        }
        return tok.encode(text)
    }

    private func firstOutputName(_ session: ORTSession) -> String {
        let names = (try? session.outputNames()) ?? []
        return names.first ?? ""
    }

    private static func tensorInt64(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(capacity: values.count * MemoryLayout<Int64>.size) ?? NSMutableData()
        values.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                data.append(base, length: values.count * MemoryLayout<Int64>.size)
            }
        }
        return try ORTValue(tensorData: data, elementType: .int64,
                            shape: shape.map { NSNumber(value: $0) })
    }
}

#endif
