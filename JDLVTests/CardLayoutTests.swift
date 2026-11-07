import XCTest
@testable import JDLV

// R1 设计系统 v2：网格/卡片布局公式单测（13 §3.4 / §6.1 CardLayoutTests、GridRowsTests）。
final class CardLayoutTests: XCTestCase {

    // MARK: cellWidth 公式（iPhone 393pt 基准）

    func testCellWidthTwoColumns() {
        // (393 - 32 - 12) / 2 = 174.5
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 393, columns: 2), 174.5, accuracy: 0.01)
    }

    func testCellWidthThreeColumns() {
        // (393 - 32 - 24) / 3 = 112.33
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 393, columns: 3), 112.333, accuracy: 0.01)
    }

    func testCellWidthOneColumn() {
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 393, columns: 1), 361, accuracy: 0.01)
    }

    func testCellWidthIPadFourColumns() {
        // 820pt regular：4 列 = (820-32-36)/4 = 188
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 820, columns: 4), 188, accuracy: 0.01)
    }

    func testCellWidthDegenerateInput() {
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 0, columns: 2), 0)
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 393, columns: 0), 0)
        // 负可用空间钳 0
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 10, columns: 8), 0, accuracy: 0.01)
    }

    // MARK: 卡片高度公式（13 §3.4 表）

    func testMovieSmallCardHeight() {
        // 174.5 / (3/4) + 76 = 232.67 + 76 = 308.67
        XCTAssertEqual(CardLayout.movieSmallH(cellW: 174.5), 308.67, accuracy: 0.05)
    }

    func testMovieLargeCardHeight() {
        // 361 / (16/9) + 86 = 203.06 + 86 = 289.06
        XCTAssertEqual(CardLayout.movieLargeH(cellW: 361), 289.06, accuracy: 0.05)
    }

    func testShtSmallCardHeight() {
        // 174.5 / (4/5) + 68 = 218.1 + 68 = 286.1
        XCTAssertEqual(CardLayout.shtSmallH(cellW: 174.5), 286.1, accuracy: 0.05)
    }

    func testShtLargeCardHeight() {
        // 361 / 1.6 + 76 = 225.6 + 76 = 301.6
        XCTAssertEqual(CardLayout.shtLargeH(cellW: 361), 301.6, accuracy: 0.05)
    }

    func testActorCardHeight() {
        XCTAssertEqual(CardLayout.actorH(cellW: 112.333), 156.333, accuracy: 0.05)
    }

    func testHomeCardFixed() {
        // 首页横滑卡 160×289（160×4/3 + 76 ≈ 289.3）
        XCTAssertEqual(CardLayout.homeCardW, 160)
        XCTAssertEqual(CardLayout.homeCardH, 289.33, accuracy: 0.5)
        XCTAssertEqual(ComponentMetrics.homeCardWidth, 160)
        XCTAssertEqual(ComponentMetrics.homeCardHeight, 289)
    }

    func testListRowHeights() {
        XCTAssertEqual(CardLayout.articleRowH, 96)
        XCTAssertEqual(CardLayout.hotReviewRowH, 108)
        XCTAssertEqual(CardLayout.top250RowH, 112)
    }

    // MARK: 行分块（GridRowsTests）

    func testChunkExactRows() {
        let rows = GridMath.chunk([1, 2, 3, 4], columns: 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0] as? Int, 1)
        XCTAssertEqual(rows[0][1] as? Int, 2)
        XCTAssertEqual(rows[1][0] as? Int, 3)
        XCTAssertEqual(rows[1][1] as? Int, 4)
    }

    func testChunkLastRowPlaceholder() {
        // 5 个 2 列 → 3 行，最后一行 1 个元素 + 1 个 nil 占位
        let rows = GridMath.chunk([1, 2, 3, 4, 5], columns: 2)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[2][0] as? Int, 5)
        XCTAssertNil(rows[2][1])
    }

    func testChunkSingleColumn() {
        let rows = GridMath.chunk([1, 2, 3], columns: 1)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.count == 1 })
    }

    func testChunkEmpty() {
        XCTAssertTrue(GridMath.chunk([Int](), columns: 2).isEmpty)
    }

    func testChunkRowWidthNeverExceedsColumns() {
        let rows = GridMath.chunk(Array(1...7), columns: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.count == 3 })
        XCTAssertEqual(rows[2].compactMap { $0 }.count, 1)
    }

    // MARK: token（设计系统 v2）

    func testSpaceAndRadiusTokens() {
        XCTAssertEqual(ComponentMetrics.pageMargin, 16)
        XCTAssertEqual(ComponentMetrics.gridSpacing, 12)
        XCTAssertEqual(ComponentMetrics.textBlockSmall, 76)
        XCTAssertEqual(ComponentMetrics.textBlockLarge, 86)
        XCTAssertEqual(ComponentMetrics.touchMin, 44)   // HIG 44
        XCTAssertEqual(Radius.card, 12)
        XCTAssertEqual(Radius.image, 10)
        XCTAssertEqual(Radius.chip, 8)
        XCTAssertEqual(Radius.sheet, 16)
    }
}
