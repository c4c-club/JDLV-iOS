import SwiftUI

//
//  Metrics.swift —— 通用组件尺寸 token（07 B 节 / 08 A.5 / 10 §0 逐项）。
//
//  对位关系（Android dp → iOS pt 1:1）：
//  - 搜索条 44pt 输入框（总高≈52 = 44 + 上下 4pt padding）+ 圆角 22（S11-P1 压矮定稿，勿回退 56/68）
//  - chips / 下拉 36pt（AppToggleChip 外层精确 36，旧版 52 的教训）
//  - 最小触控 36pt；主按钮/操作行 48pt（FilledTonalButton heightIn(min=48)）
//  - 卡片：1pt 描边 + 2pt 投影（MovieCard/ShtCard/ActorCard/ArticleCard 同款 Card 规格）
//  - 图片/骨架块圆角 10pt；卡片内容内边距 8pt；卡片容器圆角 12（Material Card 默认）
//  - 骨架行高 180pt（07 B4：每行 Row(height 180, padding v6)）
//  - 骨架呼吸动画 0.25 → 0.55，700ms 线性往复（tween 700ms LinearEasing 无限循环）
//  - 下拉刷新触发阈值 64pt（distanceFraction 分母）
//  - 恢复横幅 6 秒自消（10 §0.1 / 07 A5）
//
enum ComponentMetrics {
    // 搜索条（SearchBarCompact）
    static let searchBarHeight: CGFloat = 44
    static let searchBarRadius: CGFloat = 22
    static let searchBarBlockHeight: CGFloat = 52
    static let searchClearButton: CGFloat = 36

    // chips / 下拉 / 触控
    static let chipHeight: CGFloat = 36
    static let dropdownHeight: CGFloat = 36
    /// 最小触控目标（iOS HIG 44pt；13 §3.2 —— 旧值 36 已弃用，仅存量引用待 R2–R9 迁移）
    static let touchMin: CGFloat = 44
    static let buttonMin: CGFloat = 48

    // 卡片
    static let cardCorner: CGFloat = 12
    static let cardStroke: CGFloat = 1
    static let cardElevation: CGFloat = 2
    static let cardPadding: CGFloat = 8

    // 设计系统 v2 网格/页面（13 §3.2 Tokens）
    static let pageMargin: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    /// 卡片文本块固定高度（小图 76 / 大图 86；标题 2 行预留）
    static let textBlockSmall: CGFloat = 76
    static let textBlockLarge: CGFloat = 86
    /// 首页横滑卡宽（160×289：393pt 屏可见 2.2 张）
    static let homeCardWidth: CGFloat = 160
    static let homeCardHeight: CGFloat = 289

    // 图片 / 骨架
    static let imageCorner: CGFloat = 10
    static let skeletonRowHeight: CGFloat = 180
    static let skeletonAlphaMin: CGFloat = 0.25
    static let skeletonAlphaMax: CGFloat = 0.55
    static let skeletonAnimDuration: Double = 0.7

    // 下拉刷新 / 横幅
    static let refreshThreshold: CGFloat = 64
    static let restoredBannerMs: Int64 = 6000
}
