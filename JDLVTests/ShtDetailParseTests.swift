import XCTest
@testable import JDLV

// R3 问题 10：98t 帖子详情多形态解析单测（13 §6.1 ShtDetailParseTests，5 形态）。
final class ShtDetailParseTests: XCTestCase {

    // 形态 1：blocks [[String:Any]]（Q 层标准输出）
    func testParseBlocksDictArray() {
        let d: [String: Any] = [
            "blocks": [
                ["t": "第一段", "b": "1"],
                ["i": "https://img/x.jpg", "sz": 120],
            ]
        ]
        let p = ShtThreadData.parse(d, tid: "1")
        XCTAssertEqual(p.blocks.count, 2)
        XCTAssertEqual(p.blocks[0].t, "第一段")
        XCTAssertEqual(p.blocks[0].isBold, true)
        XCTAssertEqual(p.blocks[1].i, "https://img/x.jpg")
    }

    // 形态 2：blocks 为 JSON 字符串
    func testParseBlocksJsonString() {
        let json = "[{\"t\":\"JSON 段落\"},{\"t\":\"第二段\",\"b\":\"true\"}]"
        let d: [String: Any] = ["blocks": json]
        let p = ShtThreadData.parse(d, tid: "2")
        XCTAssertEqual(p.blocks.count, 2)
        XCTAssertEqual(p.blocks[0].t, "JSON 段落")
        XCTAssertEqual(p.blocks[1].isBold, true)
    }

    // 形态 3：blocks 为 [String] 纯段落
    func testParseBlocksStringArray() {
        let d: [String: Any] = ["blocks": ["段落一", "段落二"]]
        let p = ShtThreadData.parse(d, tid: "3")
        XCTAssertEqual(p.blocks.count, 2)
        XCTAssertEqual(p.blocks[0].t, "段落一")
    }

    // 形态 4：blocks 空 + article 纯文本 → 按空行分段
    func testParsePlainArticleFallback() {
        let d: [String: Any] = ["article": "第一段文字。\n\n第二段文字。\n\n\n第三段。"]
        let p = ShtThreadData.parse(d, tid: "4")
        XCTAssertEqual(p.blocks.count, 3)
        XCTAssertEqual(p.blocks[2].t, "第三段。")
        XCTAssertTrue(p.isLiterature)
    }

    // 形态 5：images/magnets 多形态 + HTML entity 解码
    func testParseImagesAndMagnetsPolymorphic() {
        let d: [String: Any] = [
            "images": [
                "https://img/a.jpg",
                ["url": "https://img/b.jpg"],
                ["src": "https://img/c.jpg"],
                ["image": "https://img/d.jpg"],
            ],
            "magnets": [
                ["hash": "abc123", "name": "pack.torrent", "size": "1.00 GiB",
                 "files_count": 3, "link": ""],
                "magnet:?xt=urn:btih:def456&dn=x",
            ],
            "title": "A &amp; B &#39;quoted&#39; &lt;tag&gt;",
        ]
        let p = ShtThreadData.parse(d, tid: "5")
        XCTAssertEqual(p.images, ["https://img/a.jpg", "https://img/b.jpg",
                                  "https://img/c.jpg", "https://img/d.jpg"])
        XCTAssertEqual(p.magnets.count, 2)
        XCTAssertEqual(p.magnets[0].displayLink, "magnet:?xt=urn:btih:abc123", "空 link 回落拼 hash")
        XCTAssertEqual(p.magnets[1].displayLink, "magnet:?xt=urn:btih:def456&dn=x", "裸链接原样")
        XCTAssertEqual(p.title, "A & B 'quoted' <tag>", "HTML entity 解码")
    }

    func testDecodeEntities() {
        XCTAssertEqual(ShtThreadData.decodeEntities("&amp;lt;"), "&lt;")
        XCTAssertEqual(ShtThreadData.decodeEntities("&nbsp;"), " ")
        XCTAssertEqual(ShtThreadData.decodeEntities("&quot;x&quot;"), "\"x\"")
        XCTAssertEqual(ShtThreadData.decodeEntities("plain"), "plain")
    }

    func testUseReaderBodyBranches() {
        // 小说区 → ReaderBody
        var d: [String: Any] = ["cat_name": "小说文学区",
                                "blocks": [["t": "正文"]]]
        var p = ShtThreadData.parse(d, tid: "6")
        XCTAssertTrue(p.useReaderBody)
        // 图片贴（自拍图片区 + images）：isImagePost=true 但 isLiterature=false → 不吃 ReaderBody（D5）
        d = ["cat_name": "自拍图片区", "images": ["https://img/a.jpg"]]
        p = ShtThreadData.parse(d, tid: "7")
        XCTAssertTrue(p.isImagePost)
        XCTAssertFalse(p.useReaderBody)
        // 普通磁力贴 → 非 ReaderBody（blocks 普通渲染/无 blocks）
        d = ["cat_name": "色花帖区", "magnets": [["hash": "h1"]]]
        p = ShtThreadData.parse(d, tid: "8")
        XCTAssertFalse(p.useReaderBody)
        XCTAssertTrue(p.needsEmptyFallback == false)
    }
}
