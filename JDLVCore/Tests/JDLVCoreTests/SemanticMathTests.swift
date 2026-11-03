//
//  SemanticMathTests.swift
//  JDLVCoreTests
//
//  P11 语义数值工具单测（SemanticMath: dot / l2normalize / int8Decode / score）。
//  对齐 Android data/Semantic.kt score() 口径（docs/_extract/12_img_sem.md §7.4,
//  ★ NA-08 维度一致性校验）与抓取端 emb_to_int8 = round(v*127) 的还原语义。
//
//  Linux 兼容: 全部同步断言。
//

import XCTest
@testable import JDLVCore

final class SemanticMathTests: XCTestCase {

    // MARK: - dot

    func testDotOrthogonalIsZero() {
        XCTAssertEqual(SemanticMath.dot([1, 0, 0], [0, 1, 0]), 0, accuracy: 1e-7)
        XCTAssertEqual(SemanticMath.dot([1, 0], [0, -1]), 0, accuracy: 1e-7)
    }

    func testDotSameDirectionIsSumOfSquares() {
        XCTAssertEqual(SemanticMath.dot([2, 3], [2, 3]), 13, accuracy: 1e-6)
        // 归一化后同向 = 1
        let a = SemanticMath.l2normalize([3, 4])
        XCTAssertEqual(SemanticMath.dot(a, a), 1, accuracy: 1e-6)
    }

    func testDotOppositeIsNegative() {
        XCTAssertEqual(SemanticMath.dot([1, 2], [-1, -2]), -5, accuracy: 1e-6)
    }

    func testDotEmptyIsZero() {
        XCTAssertEqual(SemanticMath.dot([], []), 0)
    }

    func testDotDimMismatchIsNegativeInfinity() {
        // ★ NA-08: 维度不一致一律 -inf（禁止混算 384/512 维）
        XCTAssertEqual(SemanticMath.dot([1, 2, 3], [1, 2]), -Float.infinity)
        XCTAssertEqual(SemanticMath.dot([1], []), -Float.infinity)
    }

    // MARK: - l2normalize

    func testL2NormalizeUnitLength() {
        let v = SemanticMath.l2normalize([3, 4])
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-6)
        let norm = (v[0] * v[0] + v[1] * v[1]).squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-6)
    }

    func testL2NormalizeAlreadyUnit() {
        let v = SemanticMath.l2normalize([1, 0])
        XCTAssertEqual(v[0], 1, accuracy: 1e-7)
        XCTAssertEqual(v[1], 0, accuracy: 1e-7)
    }

    func testL2NormalizeZeroVectorUsesFloor() {
        // norm = 0 → 下限 1e-9（Android coerceAtLeast(1e-9f), 不产生 NaN）
        let v = SemanticMath.l2normalize([0, 0])
        XCTAssertFalse(v[0].isNaN)
        XCTAssertFalse(v[1].isNaN)
        XCTAssertEqual(v[0], 0, accuracy: 1e-6)
    }

    func testL2NormalizeEmpty() {
        XCTAssertTrue(SemanticMath.l2normalize([]).isEmpty)
    }

    // MARK: - int8Decode

    func testInt8DecodeBoundaries() {
        // b = Float(Int8(bitPattern: byte)) / 127.0（有符号字节还原）
        let decoded = SemanticMath.int8Decode(Data([127, 128, 0, 1, 255]))
        XCTAssertEqual(decoded[0], 1.0, accuracy: 1e-6)             // 127 → +1.0
        XCTAssertEqual(decoded[1], -128.0 / 127.0, accuracy: 1e-6)  // 0x80 → Int8 -128
        XCTAssertEqual(decoded[2], 0, accuracy: 1e-7)               // 0 → 0
        XCTAssertEqual(decoded[3], 1.0 / 127.0, accuracy: 1e-7)     // 1 → 1/127
        XCTAssertEqual(decoded[4], -1.0 / 127.0, accuracy: 1e-7)    // 0xFF → Int8 -1
    }

    func testInt8DecodeRoundTrip() {
        // 抓取端 v → int8: round(v*127)；还原 ≈ v（误差 ≤ 1/254）
        let original: [Float] = [0.5, -0.5, 0.0, 0.999, -0.999, 0.123]
        let bytes = original.map { b -> UInt8 in
            let q = ($0 * 127.0).rounded()
            return UInt8(bitPattern: Int8(clamping: Int(q)))
        }
        let back = SemanticMath.int8Decode(Data(bytes))
        for (a, b) in zip(original, back) {
            XCTAssertEqual(b, a, accuracy: 1.0 / 127.0 + 1e-6)
        }
    }

    func testInt8DecodeEmpty() {
        XCTAssertTrue(SemanticMath.int8Decode(Data()).isEmpty)
    }

    // MARK: - score（Android Semantic.score 逐字口径）

    func testScoreSameVector() {
        // 查询 = L2 归一化向量; blob 为同一向量 int8 量化 → 分数接近 1
        let q = SemanticMath.l2normalize([0.3, -0.4, 0.5, 0.6, 0.7])
        let bytes = q.map { UInt8(bitPattern: Int8(clamping: Int(($0 * 127.0).rounded()))) }
        let s = SemanticMath.score(query: q, blob: Data(bytes))
        XCTAssertEqual(s, 1, accuracy: 0.01)
    }

    func testScoreDimMismatchIsNegativeInfinity() {
        let q: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(SemanticMath.score(query: q, blob: Data([1, 2])), -Float.infinity)
        XCTAssertEqual(SemanticMath.score(query: q, blob: Data([1, 2, 3, 4])), -Float.infinity)
        // 空 blob → -inf（Android: blob.isEmpty() 先判）
        XCTAssertEqual(SemanticMath.score(query: q, blob: Data()), -Float.infinity)
    }

    func testScoreThresholdSemantics() {
        // s >= threshold（闭区间）; 正交向量分数 ≈ 0（量化噪声 <0.01）, 过不了 0.05 档
        let q = SemanticMath.l2normalize([1, 0])
        let blob = SemanticMath.l2normalize([0, 1]).map {
            UInt8(bitPattern: Int8(clamping: Int(($0 * 127.0).rounded())))
        }
        let s = SemanticMath.score(query: q, blob: Data(blob))
        XCTAssertLessThan(abs(s), 0.01, "正交向量分数应≈0（仅量化噪声）")
        XCTAssertFalse(s >= 0.05, "0.05 阈值下正交向量不应命中")
    }
}
