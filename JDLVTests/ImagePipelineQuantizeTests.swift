import XCTest
@testable import JDLV

// R6 PHASE2：maxPixel 档位量化 —— 亚像素/布局微抖不换缓存键（u|maxPixel|half），
// 同档位共享内存缓存与一次降采样解码；0 = 不限，保持不变。
final class ImagePipelineQuantizeTests: XCTestCase {

    func testQuantizeMaxPixelBuckets() {
        XCTAssertEqual(ImagePipeline.quantizeMaxPixel(0), 0, "0 = 不限，不量化")
        XCTAssertEqual(ImagePipeline.quantizeMaxPixel(1), 256)
        XCTAssertEqual(ImagePipeline.quantizeMaxPixel(255), 256)
        XCTAssertEqual(ImagePipeline.quantizeMaxPixel(256), 256)
        XCTAssertEqual(ImagePipeline.quantizeMaxPixel(257), 512)
        XCTAssertEqual(ImagePipeline.quantizeMaxPixel(1200), 1280)
        XCTAssertEqual(ImagePipeline.quantizeMaxPixel(4096), 4096)
    }
}
