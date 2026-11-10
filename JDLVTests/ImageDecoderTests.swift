import XCTest
import JDLVCore
@testable import JDLV

// R4 P4 图片降采样门禁（任务 05 §7.2.4）：
//  - 1×1 / 100×100 / 1000×1000 PNG 在 maxPixel=16/64/256 下输出最长边 ≤ maxPixel；
//  - maxPixel=0 = 不限（尺寸保持）；
//  - 非法数据返回 nil（管线走 recordFailure，不崩溃）；
//  - 半图裁切语义（CoverHalf.cropRect + cg.cropping，即 ImagePipeline.applyHalf 的实现口径）：
//    宽图右/左半宽 = 原宽一半，整图模式不裁。
final class ImageDecoderTests: XCTestCase {

    private func makePNG(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(img.pngData())
    }

    func testDownsampleCapsMaxPixel() throws {
        for (w, h) in [(1, 1), (100, 100), (1000, 1000)] {
            let png = try makePNG(width: w, height: h)
            for maxPixel in [16, 64, 256] {
                let img = try XCTUnwrap(ImageDecoder.downsample(png, maxPixel: maxPixel),
                                        "\(w)x\(h) @ maxPixel=\(maxPixel) 应解码成功")
                let cg = try XCTUnwrap(img.cgImage)
                XCTAssertLessThanOrEqual(max(cg.width, cg.height), maxPixel,
                                         "\(w)x\(h) @ maxPixel=\(maxPixel) 最长边必须 ≤ \(maxPixel)")
            }
        }
    }

    func testDownsampleNoLimitKeepsSize() throws {
        let png = try makePNG(width: 100, height: 100)
        let img = try XCTUnwrap(ImageDecoder.downsample(png, maxPixel: 0))
        let cg = try XCTUnwrap(img.cgImage)
        XCTAssertEqual(max(cg.width, cg.height), 100, "maxPixel=0 = 不限（全尺寸单次解码）")
    }

    func testDownsampleInvalidDataReturnsNil() {
        XCTAssertNil(ImageDecoder.downsample(Data(), maxPixel: 64), "空数据必须返回 nil")
        XCTAssertNil(ImageDecoder.downsample(Data("not an image".utf8), maxPixel: 64),
                     "非图片字节必须返回 nil")
    }

    func testHalfCropSemanticsOnDownsampledWideImage() throws {
        // 宽图 300×200 → maxPixel 150 → 150×100（宽 ≥ 高×1.2 → 参与半图裁切）
        let png = try makePNG(width: 300, height: 200)
        let img = try XCTUnwrap(ImageDecoder.downsample(png, maxPixel: 150))
        let cg = try XCTUnwrap(img.cgImage)
        XCTAssertEqual(cg.width, 150, "降采样后宽 = 150")
        XCTAssertEqual(cg.height, 100, "降采样后高 = 100")

        // mode 0（右半）/ mode 1（左半）：半宽 = 原宽一半；mode 2（整张）= 不裁
        let right = try XCTUnwrap(CoverHalf.cropRect(cw: cg.width, ch: cg.height, mode: 0))
        let cutRight = try XCTUnwrap(cg.cropping(to: right))
        XCTAssertEqual(cutRight.width, cg.width / 2, "右半宽 = 原宽一半")
        XCTAssertEqual(cutRight.height, cg.height, "高度不变")

        let left = try XCTUnwrap(CoverHalf.cropRect(cw: cg.width, ch: cg.height, mode: 1))
        let cutLeft = try XCTUnwrap(cg.cropping(to: left))
        XCTAssertEqual(cutLeft.width, cg.width / 2, "左半宽 = 原宽一半")
        XCTAssertEqual(cutLeft.height, cg.height, "高度不变")

        XCTAssertNil(CoverHalf.cropRect(cw: cg.width, ch: cg.height, mode: 2),
                     "整张模式不裁（回原图）")
    }

    func testHalfCropSkipsPortraitImage() throws {
        // 竖图（w < h×1.2）不参与半图裁切 → cropRect 返回 nil（回原图语义）
        let png = try makePNG(width: 100, height: 300)
        let img = try XCTUnwrap(ImageDecoder.downsample(png, maxPixel: 100))
        let cg = try XCTUnwrap(img.cgImage)
        XCTAssertNil(CoverHalf.cropRect(cw: cg.width, ch: cg.height, mode: 0),
                     "竖图不裁半（cropRect = nil）")
    }
}
