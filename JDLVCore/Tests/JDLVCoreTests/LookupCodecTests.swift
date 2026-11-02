import Foundation
import XCTest
@testable import JDLVCore

/// B7. LookupCodecTest —— 反查跳转载荷编解码（6 用例）。
/// JSON{ label, sort?, f:{12 字段} } → Base64 URL-safe 无填充（UTF-8）；
/// 解码失败 → nil（调用方兜底空态，绝不崩溃）。
final class LookupCodecTests: XCTestCase {

    /// roundTrip_fullFields：12 字段全填 + label + sort 往返全等
    func testRoundTripFullFields() {
        let filters = Filters(
            year: "2024", month: "08", maker: "プレステージ", letter: "a",
            tags: "巨乳,人妻,單體作品", magnet: true, cnsub: true, canPlay: true,
            single: true, seriesId: "s0001", directorId: "d0001", publisherId: "p0001")
        let spec = LookupSpec(filters: filters, label: "女优反查：某某（2024）", sort: "release_date")

        let decoded = LookupCodec.decode(LookupCodec.encode(spec))

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, spec)
        XCTAssertEqual(decoded?.filters, filters)
        XCTAssertEqual(decoded?.label, "女优反查：某某（2024）")
        XCTAssertEqual(decoded?.sort, "release_date")
    }

    /// roundTrip_chineseLabel：全角中文 label 往返不变
    func testRoundTripChineseLabel() {
        let spec = LookupSpec(
            filters: Filters(year: "2024", month: "12"),
            label: "系列：中文字幕（简体）")

        let decoded = LookupCodec.decode(LookupCodec.encode(spec))

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.label, "系列：中文字幕（简体）")
        XCTAssertEqual(decoded?.filters, Filters(year: "2024", month: "12"))
    }

    /// roundTrip_sortNullOmitted：sort=nil 往返后仍 nil；filters.year 保留
    func testRoundTripSortNullOmitted() {
        let spec = LookupSpec(filters: Filters(year: "2024"), label: "年份反查", sort: nil)

        let decoded = LookupCodec.decode(LookupCodec.encode(spec))

        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.sort)
        XCTAssertEqual(decoded?.filters.year, "2024")
        XCTAssertEqual(decoded?.label, "年份反查")
    }

    /// encoded_isUrlSafe_noPadding：encode 结果不含 '+'、'/'、'='，且非空
    func testEncodedIsUrlSafeNoPadding() {
        // 内容刻意包含 + / = 等字符，逼迫 base64 出现需替换的符号
        let spec = LookupSpec(
            filters: Filters(tags: "a+b/c=d 中文字幕"),
            label: "系列：中文字幕（简体）")

        let encoded = LookupCodec.encode(spec)

        XCTAssertFalse(encoded.isEmpty)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(
            encoded.allSatisfy { allowed.contains($0) },
            "只允许 URL-safe base64 字母表：\(encoded)")
        // URL-safe 载荷必须还能原样解码
        XCTAssertEqual(LookupCodec.decode(encoded), spec)
    }

    /// decode_invalidPayload_returnsNull：坏载荷一律 nil（绝不崩溃）
    func testDecodeInvalidPayloadReturnsNull() {
        XCTAssertNil(LookupCodec.decode("%%%not-base64%%%"))
        XCTAssertNil(LookupCodec.decode(""))
        // 合法 base64 但非 JSON："abcdefghijklmnop"
        XCTAssertNil(LookupCodec.decode("YWJjZGVmZ2hpamtsbW5vcA"))
    }

    /// roundTrip_defaultFilters：默认 Filters + label="反查" 往返等值
    func testRoundTripDefaultFilters() {
        let spec = LookupSpec()
        XCTAssertEqual(spec.label, "反查")

        let decoded = LookupCodec.decode(LookupCodec.encode(spec))

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, spec)
        XCTAssertEqual(decoded?.filters, Filters())
        XCTAssertEqual(decoded?.label, "反查")
        XCTAssertNil(decoded?.sort)
    }
}
