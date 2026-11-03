# -*- coding: utf-8 -*-
"""gen_tokenizer_golden.py —— 生成语义分词 golden fixture（P11）。

用本机 Python tokenizers（0.22.2）加载 models/minilm/tokenizer.json，对 ≥200 条
语料（中文/英文/数字/番号/标点/emoji/长文本/空串/特殊空白/控制字符等）逐条
encode，只存 {text, ids, mask} 到
JDLVCore/Tests/JDLVCoreTests/Fixtures/tokenizer_golden.json。

TokenizerTests 用 BertTokenizer（Swift 移植）逐条断言完全相等 —— 100% 相等是硬门禁
（对齐 docs/_extract/12_img_sem.md §7.1：分词同源保证 ids 一致）。

用法: python tools/gen_tokenizer_golden.py [--tokenizer <path>] [--out <path>]
"""
import argparse
import json
import os
import random
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

DEFAULT_TOKENIZER = r"C:\Users\RuiZh\Desktop\jav\models\minilm\tokenizer.json"
DEFAULT_OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "JDLVCore", "Tests", "JDLVCoreTests", "Fixtures", "tokenizer_golden.json")


def build_corpus():
    """语料: 固定真实用例 + 确定性随机（覆盖分词各环节的边界）。"""
    cases = [
        # 空串 / 纯空白
        "", " ", "   ", "\t", "\n", "\r\n", "\t \n  ", "\u3000", "\u00a0",
        "  leading", "trailing  ", "  both  ", "a b", "a  b", " a ", "a\n\nb",
        # 英文
        "hello world", "Hello World!", "The quick brown fox jumps over the lazy dog.",
        "semantic search embedding", "ONNX Runtime inference", "MiniLM L12 v2",
        "a", "I", "OK", "yes no maybe", "CamelCase snake_case kebab-case",
        "don't can't won't", "e-mail: user@example.com", "https://example.com/path?q=1",
        # 数字 / 番号
        "0123456789", "42", "3.14159", "1,000,000", "2024-01-02", "12:34:56",
        "FC2-PPV-1234567", "MIDE-882", "SSIS-699", "IPX-001", "abp-999",
        "259LUXU-1567", "HEYZO 1234", "Tokyo-Hot n1234", "ID:9527", "#9527",
        "25cm", "4K 2160p", "1080p HEVC", "x264-aac", "vol.12", "Part 3/5",
        # 中文
        "你好，世界！", "中文字幕", "高清无码", "国产原创", "女优合集",
        "东京热", "无码流出", "有码破解", "中文字幕无码流出",
        "这是一个用于语义搜索的测试句子，包含标点、数字123与英文words。",
        "语义搜索将自然语言查询映射为向量，再用余弦相似度检索候选。",
        "示  例", "单字", "重", "复", "词",
        # 日文 / 韩文
        "こんにちは世界", "カタカナ ひらがな", "日本語テキストの意味検索",
        "キロメートル", "한국어 텍스트", "한글 의미 검색",
        # 全角 / 记号 / 数字形式
        "ＡＢＣ１２３", "！？：；", "（全角括号）", "【方头括号】", "「引用」",
        "①②③", "⑴⑵⑶", "½ ¾ ⅓", "№ ™ © ®", "℃ ℃", "㎝ ㎞ ㎏",
        "１２３４５６７８９０", "￡ € ¥ $", "％％", "＃＠＆＊",
        # 拉丁变音 / 连字
        "café naïve résumé", "ÀÉÎÕÜ", "ąćęłńóśźż", "ÄÖÜ ß", "ﬁle ﬂow ﬀ",
        "Škoda Peugeot Citroën", "žůžo", "Ǧ ǩ Ǳ",
        # 西里尔 / 希腊 / 阿拉伯 / 希伯来 / 泰文
        "Привет мир", "много букв", "Μια πρόταση", "αβγδ",
        "مرحبا بالعالم", "שלום עולם", "สวัสดีครับ", "ภาษาไทย",
        # emoji / 合成序列
        "👍", "👍🏽", "🇯🇵", "🇯🇵🇰🇷", "👨‍👩‍👧‍👦", "👩‍💻", "🏳️‍🌈",
        "❤️", "1️⃣2️⃣3️⃣", "✅❌⚠️", "😀😃😄", "🤝🏽 emoji 👨‍👩‍👧‍👦",
        "™️", "☎️", "e\u0301 combining", "e\u0301\u0302 stacked", "a\u0327\u0301",
        # 特殊空白 / 控制字符 / 零宽
        "a\u200bb", "a\u200bb\u200bc", "\ufeffBOM", "a\u0000b", "a\u0001b\u001fc",
        "x\u007fy", "a\u0085b", "ab", "ab", "ab", "a　b",
        "word\u2028next", "\u2060word", "a​b",
        # 标点密集 / 混合
        "Mr. O'Neill-smith (USA) [2024] {100%} <tag> & 5+6=11?",
        "a/b\\c|d~e^f", "\"quotes\" 'single' `tick`", "...!?;;,::---",
        "中文English日本語mixed123½™👍", "FC2 PPV 1234567 中文字幕 1080p",
        # real-world 查询风格
        "高颜值 里番", "贪吃蛇 素人", "美脚 OL", "素人 个人撮影",
        "无码 中文字幕 高清", "人妻 熟女", "巨乳 制服", "痴汉 电车",
        "JAV collection 2024", "uncensored leaked", "chinese subtitle",
        "tokyo hot", "caribbeancom 010124-001", "1pondo 010124_001",
        "10musume 010124_01", "pacopacomama 010124_123",
        # added-token 形态（special token 应被原文切出）
        "<s>", "</s>", "<unk>", "<pad>", "<mask>", "a<s>b", "<mask>cd",
        "<unk><unk>", "x<s>y</s>z", "<pad> <mask>",
        # 长文本（触发 truncation: max_length=128, 先截 126 再加 <s>/</s>）
        "word " * 40,
        "This is a fairly long English paragraph used to exercise the truncation "
        "path of the tokenizer; it keeps going and going so that the encoded id "
        "sequence definitely exceeds one hundred and twenty-eight tokens in "
        "total length for sure indeed. " * 2,
        "语义长文本" * 60,
        "番号 FC2-PPV-1234567 中文字幕 无码流出 高清 1080p " * 20,
        "a" * 300,
        "斯" * 130,
        ("The quick brown fox jumps over the lazy dog. " * 12),
        ("Hello 世界 " * 45),
    ]
    # 确定性随机（与移植期 fuzz 同池, 固定种子 → fixture 可复现）
    random.seed(20261104)
    pool_words = ["hello", "world", "番号", "FC2", "PPV-123", "中文字幕", "無码", "MIDE-882",
                  "actress", "JAV", "女优", "高清", "1080p", "HEVC", "kimetsu", " démon",
                  "Минск", "παράδειγμα", " Japanese", "字幕组", "SSIS-699", "caribbean",
                  "com", "www.example.com", "<unknown>", "Tokyo", "東京", "ホテイ", "한국어",
                  "Việt", "Thái", "ภาษาไทย", "עברית", "العربية", "русский", "e-mail",
                  "2024年", "1月2日", "P12", "ID:9527", "#tag", "(副标题)", "[720P]"]
    pool_marks = ["\u0301", "\u0308", "\u0327", "\u0300\u0301", "\u093C", "\u0654"]
    pool_emoji = ["👨\u200d👩\u200d👧\u200d👦", "🤝🏽", "🇯🇵", "👍🏻", "👩\u200d💻",
                  "️", "⃣", "1️⃣", "🏳️\u200d🌈", "❤️", "✅"]
    pool_ws = [" ", "  ", "\t", "\n", "\r\n", "\u00a0", "\u2000", "\u200b", "\u3000",
               "\u2028", "\u000b", "\u000c", "\u0085", "\ufeff"]
    pool_ctrl = ["\u0000", "\u0001", "\u001f", "\u007f", "\u009f", "\u200e", "\u202a"]
    pool_odd = ["①", "㊙", "㎞", "ﬁ", "½", "№", "™", "™️", "×", "÷", "≥", "°C",
                "ﷺ", "ﭏ", "Ａ", "１", "𝕏", "𝟙", "ᵃ", "₊", "Æ", "ß", "Ǧ", "ǩ"]
    for _ in range(80):
        n = random.randint(1, 14)
        parts = []
        for _ in range(n):
            k = random.random()
            if k < 0.42:
                parts.append(random.choice(pool_words))
            elif k < 0.52:
                parts.append(random.choice(pool_emoji))
            elif k < 0.60:
                base = random.choice("aeiouztcAGZFetcher")
                parts.append(base + random.choice(pool_marks))
            elif k < 0.70:
                parts.append(random.choice(pool_ws))
            elif k < 0.78:
                parts.append(random.choice(pool_ctrl))
            elif k < 0.88:
                parts.append(random.choice(pool_odd))
            else:
                parts.append("".join(random.choice("0123456789ABCdef中国日-_.:/")
                                     for _ in range(random.randint(1, 8))))
        cases.append("".join(parts))
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokenizer", default=DEFAULT_TOKENIZER)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    from tokenizers import Tokenizer
    tok = Tokenizer.from_file(args.tokenizer)

    cases = build_corpus()
    # 去重保持顺序
    seen = set()
    uniq = []
    for c in cases:
        if c not in seen:
            seen.add(c)
            uniq.append(c)

    out = []
    for text in uniq:
        enc = tok.encode(text)
        out.append({"text": text, "ids": list(enc.ids), "mask": list(enc.attention_mask)})

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    trunc = sum(1 for e in out if len(e["ids"]) >= 128)
    empty = sum(1 for e in out if len(e["ids"]) == 2)
    print("golden: %d 条 → %s" % (len(out), args.out))
    print("  触发截断(128): %d, 仅特殊token(ids==[0,2]): %d" % (trunc, empty))


if __name__ == "__main__":
    main()
