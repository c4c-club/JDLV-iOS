import Foundation
import CoreGraphics

//
//  CardLayout.swift —— 卡片尺寸公式（13 §3.4；纯函数，CardLayoutTests 单测）。
//
//  cardH = imgH + textBlock；imgH = cellW / ratio。
//  文本块：MovieCard 小图 76 / 大图 86；ShtCard 小图 68 / 大图 76；ActorCard 44。
//  首页横滑卡 160×289 = 160×4/3 + 76。
//

enum CardLayout {
    // MARK: 图片高

    static func imgH(cellW: CGFloat, ratio: CGFloat) -> CGFloat {
        guard ratio > 0, cellW > 0 else { return 0 }
        return cellW / ratio
    }

    // MARK: 卡片总高（imgH + textBlock）

    /// MovieCard 小图 3:4 + 76
    static func movieSmallH(cellW: CGFloat) -> CGFloat { imgH(cellW: cellW, ratio: 3.0 / 4.0) + 76 }
    /// MovieCard 大图 16:9 + 86
    static func movieLargeH(cellW: CGFloat) -> CGFloat { imgH(cellW: cellW, ratio: 16.0 / 9.0) + 86 }
    /// ShtCard 小图 4:5 + 68
    static func shtSmallH(cellW: CGFloat) -> CGFloat { imgH(cellW: cellW, ratio: 4.0 / 5.0) + 68 }
    /// ShtCard 大图 16:10 + 76
    static func shtLargeH(cellW: CGFloat) -> CGFloat { imgH(cellW: cellW, ratio: 16.0 / 10.0) + 76 }
    /// ActorCard 1:1 + 44
    static func actorH(cellW: CGFloat) -> CGFloat { cellW + 44 }

    /// 行卡固定高（List 行卡；13 §3.4）
    static let articleRowH: CGFloat = 96
    static let hotReviewRowH: CGFloat = 108
    static let top250RowH: CGFloat = 112

    /// 首页横滑卡（固定 160 宽）
    static let homeCardW: CGFloat = 160
    static var homeCardH: CGFloat { movieSmallH(cellW: homeCardW) }
}
