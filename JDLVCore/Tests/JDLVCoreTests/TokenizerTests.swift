//
//  TokenizerTests.swift
//  JDLVCoreTests
//
//  P11 语义分词 golden 对拍（硬门禁: 100% 相等）。
//
//  golden 由 tools/gen_tokenizer_golden.py 用 Python tokenizers 0.22.2 +
//  models/minilm/tokenizer.json 生成（252 条: 中文/英文/数字/番号/标点/emoji/
//  长文本/空串/特殊空白/控制字符/added-token/截断）。断言
//  BertTokenizer.encode(text) 的 ids 与 attention_mask 与 golden 完全相等
//  （对齐 docs/_extract/12_img_sem.md §7.1 分词同源铁律）。
//
//  tokenizer.json 从 Fixtures/tokenizer.json 读取（可用环境变量
//  JDLV_TOKENIZER_JSON 覆盖路径）。
//
//  Linux 兼容: 全部同步断言。
//

import XCTest
@testable import JDLVCore

final class TokenizerTests: XCTestCase {

    // MARK: - 装载

    private func loadTokenizer() throws -> BertTokenizer {
        let env = ProcessInfo.processInfo.environment["JDLV_TOKENIZER_JSON"]
        let url: URL
        if let env, !env.isEmpty {
            url = URL(fileURLWithPath: env)
        } else {
            url = Golden.fixtureURL("tokenizer.json", testFilePath: #filePath)
        }
        let data = try Golden.loadTokenizerJSON(at: url)
        return try BertTokenizer(tokenizerJSON: data)
    }

    // MARK: - golden 硬门禁（100% 相等）

    func testGoldenIdsAndMaskExactMatch() throws {
        let tok = try loadTokenizer()
        let golden = try Golden.loadTokenizerGolden(
            at: Golden.fixtureURL("tokenizer_golden.json", testFilePath: #filePath))
        XCTAssertGreaterThanOrEqual(golden.count, 200, "golden 语料 ≥200 条")
        for (i, c) in golden.enumerated() {
            let r = tok.encode(c.text)
            if r.ids != c.ids {
                let idsPrefix = r.ids.prefix(24).map(String.init).joined(separator: ",")
                let goldPrefix = c.ids.prefix(24).map(String.init).joined(separator: ",")
                XCTFail("golden[\(i)] ids 不相等 text=\(c.text.debugDescription) " +
                    "got=\(idsPrefix)…(n=\(r.ids.count)) " +
                    "want=\(goldPrefix)…(n=\(c.ids.count))")
            } else if r.mask != c.mask {
                XCTFail("golden[\(i)] mask 不相等 text=\(c.text.debugDescription)")
            }
        }
    }

    // MARK: - 结构断言（golden 之外的独立校验）

    func testEmptyAndWhitespaceProduceSpecialTokensOnly() throws {
        let tok = try loadTokenizer()
        // 空串 → <s> </s>
        XCTAssertEqual(tok.encode("").ids, [0, 2])
        XCTAssertEqual(tok.encode("").mask, [1, 1])
        // 空格（Android blank 防御 " " 占位）→ <s> </s>
        XCTAssertEqual(tok.encode(" ").ids, [0, 2])
        // 制表/换行同样被 WhitespaceSplit 删除
        XCTAssertEqual(tok.encode("\t\n").ids, [0, 2])
    }

    func testTemplateAndMaskShape() throws {
        let tok = try loadTokenizer()
        let r = tok.encode("hello world")
        XCTAssertEqual(r.ids.first, 0, "<s> 开头")
        XCTAssertEqual(r.ids.last, 2, "</s> 结尾")
        XCTAssertEqual(r.ids.count, r.mask.count)
        XCTAssertEqual(r.mask, Array(repeating: 1, count: r.ids.count))
        XCTAssertEqual(r.ids.count, 5, "hello world → <s> + 3 + </s>")
    }

    func testTruncationCap128() throws {
        let tok = try loadTokenizer()
        // 长文本: 先截 126（128 - 2 个模板 special）再加 <s>/</s> → 恰 128
        let r = tok.encode(String(repeating: "word ", count: 60))
        XCTAssertEqual(r.ids.count, 128)
        XCTAssertEqual(r.ids.first, 0)
        XCTAssertEqual(r.ids.last, 2)
    }

    func testAddedTokensExtractedFromRawText() throws {
        let tok = try loadTokenizer()
        // <s>/<mask> 等 special token 在原文上切出（不经归一化、不并词）:
        // "<mask>cd" → <s> <mask>(250001) ▁cd </s>
        XCTAssertEqual(tok.encode("<mask>cd").ids, [0, 250001, 56329, 2])
        // "a<s>b" → <s> ▁a <s> ▁b </s>（b 为独立片段 → 独立前缀 ▁）
        XCTAssertEqual(tok.encode("a<s>b").ids, [0, 10, 0, 876, 2])
    }

    func testEncodeIsRepeatable() throws {
        let tok = try loadTokenizer()
        let q = "番号 FC2-PPV-1234567 中文字幕"
        let a = tok.encode(q)
        let b = tok.encode(q)
        XCTAssertEqual(a.ids, b.ids)
        XCTAssertEqual(a.mask, b.mask)
        // struct 只读: 两次构造结果一致（可并发持有的前提）
        let tok2 = try loadTokenizer()
        XCTAssertEqual(tok2.encode(q).ids, a.ids)
    }
}
