import XCTest
@testable import JDLVCore

final class JDLVCoreTests: XCTestCase {
    func testVersionConstants() {
        XCTAssertEqual(JDLVCoreInfo.marketingVersion, "1.6.0")
        XCTAssertEqual(JDLVCoreInfo.currentProjectVersion, 1)
    }
}
