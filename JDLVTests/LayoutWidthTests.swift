import XCTest
@testable import JDLV

// R4 P3 布局宽度门禁（任务 06 §17.4.4）：GridMath.cellWidth 在 320/375/393/402/430pt 下
// 满足「columns*cellW + (columns-1)*spacing + 2*margin == pageWidth」（±0.5pt 取整误差）；
// 320pt 双列不裁切；ActorDetail 内宽口径（pageWidth-24 + margin 0）与默认口径不双重扣。
final class LayoutWidthTests: XCTestCase {

    private let spacings: [CGFloat] = [ComponentMetrics.gridSpacing]
    private let margins: [CGFloat] = [ComponentMetrics.pageMargin]

    func testCellWidthFillsContainerExactly() {
        for width in [320.0, 375.0, 393.0, 402.0, 430.0] {
            for columns in [1, 2, 3] {
                for margin in margins {
                    for spacing in spacings {
                        let cellW = GridMath.cellWidth(pageWidth: width, columns: columns,
                                                       margin: margin, spacing: spacing)
                        XCTAssertGreaterThan(cellW, 0, "width=\(width) cols=\(columns) cellW 必须 > 0")
                        let total = CGFloat(columns) * cellW
                            + CGFloat(columns - 1) * spacing
                            + 2 * margin
                        XCTAssertEqual(total, width, accuracy: 0.5,
                                       "width=\(width) cols=\(columns)：cell 总和+间距+边距必须填满容器")
                    }
                }
            }
        }
    }

    func testCellWidthNonPositiveGuard() {
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 0, columns: 2), 0, "非法宽度返回 0")
        XCTAssertEqual(GridMath.cellWidth(pageWidth: 320, columns: 0), 0, "非法列数返回 0")
    }

    /// R4 P4：女优详情内宽口径 —— pageWidth-24 + margin:0 的两列恰好填满内宽（不双重扣）
    func testActorDetailInnerWidthNoDoubleMargin() {
        for width in [320.0, 375.0, 402.0] {
            let innerW = width - 24                       // content 的 .padding(.horizontal,12)
            let cellW = GridMath.cellWidth(pageWidth: innerW, columns: 2, margin: 0)
            let total = cellW * 2 + ComponentMetrics.gridSpacing
            XCTAssertEqual(total, innerW, accuracy: 0.5,
                           "width=\(width)：两列 + spacing == 内宽（左右各 12pt 由页面 padding 负责）")
            // 无双重扣守卫（精确公式）：cellW = (内宽 - spacing) / 2；
            // 若误用「内层 padding + GridMath 默认 16 margin」双重扣 → 少 ~16pt 必挂
            XCTAssertEqual(cellW, (innerW - ComponentMetrics.gridSpacing) / 2, accuracy: 0.5,
                           "width=\(width)：cellW 必须精确等于 (内宽 - spacing)/2")
        }
    }

    /// R4 P3：首帧兜底 320（宁窄不溢出），实测宽度经 PageContainerWidthKey 到位
    func testResolvedContainerWidthFallback() {
        XCTAssertEqual(resolvedContainerWidth(0, hSize: .compact), 320,
                       "compact 兜底 = 320（不再是 393）")
        XCTAssertEqual(resolvedContainerWidth(0, hSize: nil), 320)
        XCTAssertEqual(resolvedContainerWidth(0, hSize: .regular), 768)
        XCTAssertEqual(resolvedContainerWidth(402, hSize: .compact), 402,
                       "注入值 > 0 恒用注入值")
    }
}
