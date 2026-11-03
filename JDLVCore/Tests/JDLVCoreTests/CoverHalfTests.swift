//
//  CoverHalfTests.swift
//  JDLVCoreTests
//
//  被测: JDLVCore.CoverHalf.cropRect(cw:ch:mode:) — 封面左/右半裁切纯几何
//  (对齐 Android core/img/CoverHalf.kt P4; docs/_extract/12_img_sem.md §6)。
//  语义: 800×538 合并横图取半; 0=右半(x=w/2) / 1=左半(x=0, 宽=w-x 逐字) /
//  2=整张不挂变换; 条件 w >= h*12/10 && w >= 2 (整数运算); 宽高为 0 防御。
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import JDLVCore

final class CoverHalfTests: XCTestCase {

    /// 800×538 合并横图 右半: x = w/2 = 400, 宽 = w - x = 400
    func test_rightHalfOfMergedImage() {
        XCTAssertEqual(
            CoverHalf.cropRect(cw: 800, ch: 538, mode: 0),
            CGRect(x: 400, y: 0, width: 400, height: 538))
    }

    /// 左半: x = 0（Android 逐字 宽 = w - x = w，与源码注释 "0..w/2" 矛盾处按代码保留）
    func test_leftHalfStartsAtZero() {
        XCTAssertEqual(
            CoverHalf.cropRect(cw: 800, ch: 538, mode: 1),
            CGRect(x: 0, y: 0, width: 800, height: 538))
    }

    /// 整张 (mode=2): 不挂变换 → nil
    func test_wholeImageNoTransform() {
        XCTAssertNil(CoverHalf.cropRect(cw: 800, ch: 538, mode: 2))
    }

    /// 竖图 (400×520): 宽 < 高×1.2 → 不裁
    func test_verticalImageNotCropped() {
        XCTAssertNil(CoverHalf.cropRect(cw: 400, ch: 520, mode: 0))
        XCTAssertNil(CoverHalf.cropRect(cw: 400, ch: 520, mode: 1))
    }

    /// 测试块尺寸 400×269: 269*12/10 = 322 ≤ 400 → 仍裁半 (与真图行为一致)
    func test_testImageSizeStillCropped() {
        XCTAssertEqual(
            CoverHalf.cropRect(cw: 400, ch: 269, mode: 0),
            CGRect(x: 200, y: 0, width: 200, height: 269))
    }

    /// 恰好等于阈值: h=500 → h*12/10 = 600, w=600 → 裁
    func test_boundaryRatioExactly12Over10() {
        XCTAssertEqual(
            CoverHalf.cropRect(cw: 600, ch: 500, mode: 0),
            CGRect(x: 300, y: 0, width: 300, height: 500))
        // 差 1 像素不裁
        XCTAssertNil(CoverHalf.cropRect(cw: 599, ch: 500, mode: 0))
    }

    /// 奇数宽右半: x = 801/2 = 400, 宽 = 401
    func test_oddWidthRightHalf() {
        XCTAssertEqual(
            CoverHalf.cropRect(cw: 801, ch: 538, mode: 0),
            CGRect(x: 400, y: 0, width: 401, height: 538))
    }

    /// 奇数宽左半: x = 0, 宽 = w
    func test_oddWidthLeftHalf() {
        XCTAssertEqual(
            CoverHalf.cropRect(cw: 801, ch: 538, mode: 1),
            CGRect(x: 0, y: 0, width: 801, height: 538))
    }

    /// w >= 2 下界: 1×1 不裁; 2×1 满足 (2 >= 1*12/10=1 且 w>=2) → 裁
    func test_minWidthBoundary() {
        XCTAssertNil(CoverHalf.cropRect(cw: 1, ch: 1, mode: 0))
        XCTAssertEqual(
            CoverHalf.cropRect(cw: 2, ch: 1, mode: 0),
            CGRect(x: 1, y: 0, width: 1, height: 1))
    }

    /// 宽高为 0 防御 → nil (Android Bitmap.createBitmap 抛异常 → catch 回原图)
    func test_zeroWidthDefensive() {
        XCTAssertNil(CoverHalf.cropRect(cw: 0, ch: 538, mode: 0))
    }

    /// 高为 0 防御 → nil
    func test_zeroHeightDefensive() {
        XCTAssertNil(CoverHalf.cropRect(cw: 800, ch: 0, mode: 1))
    }

    /// 负值防御 → nil
    func test_negativeDefensive() {
        XCTAssertNil(CoverHalf.cropRect(cw: -800, ch: 538, mode: 0))
        XCTAssertNil(CoverHalf.cropRect(cw: 800, ch: -538, mode: 1))
    }

    /// cacheKey 与 Android Coil Transformation 一致
    func test_cacheKey() {
        XCTAssertEqual(CoverHalf.cacheKey(0), "coverHalf_0")
        XCTAssertEqual(CoverHalf.cacheKey(1), "coverHalf_1")
    }
}
