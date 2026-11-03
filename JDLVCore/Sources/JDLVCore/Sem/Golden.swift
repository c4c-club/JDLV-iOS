import Foundation

//
//  Golden —— 测试 fixture 加载辅助（P11, 纯 Foundation）。
//
//  tokenizer_golden.json 由 tools/gen_tokenizer_golden.py 用本机 Python
//  tokenizers 0.22.2 + models/minilm/tokenizer.json 生成, 每条只存
//  {text, ids, mask}。TokenizerTests 逐条断言 BertTokenizer.encode 完全相等
//  （100% 相等 = 硬门禁, 对齐 Android DJL HuggingFaceTokenizer 同源保证）。
//

public enum Golden {

    public struct TokenizerCase: Decodable, Equatable {
        public let text: String
        public let ids: [Int]
        public let mask: [Int]
    }

    /// 测试文件同目录 Fixtures/<name>（#filePath 由测试侧传入）。
    public static func fixtureURL(_ name: String, testFilePath: StaticString) -> URL {
        let file = URL(fileURLWithPath: "\(testFilePath)")
        return file.deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// 读 tokenizer_golden.json（[ {text, ids, mask}, ... ]）。
    public static func loadTokenizerGolden(at url: URL) throws -> [TokenizerCase] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TokenizerCase].self, from: data)
    }

    /// 读 tokenizer.json 原文（供 BertTokenizer.init(tokenizerJSON:)）。
    public static func loadTokenizerJSON(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}
