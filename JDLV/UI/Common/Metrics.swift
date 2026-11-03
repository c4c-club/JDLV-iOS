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
    static let touchMin: CGFloat = 36
    static let buttonMin: CGFloat = 48

    // 卡片
    static let cardCorner: CGFloat = 12
    static let cardStroke: CGFloat = 1
    static let cardElevation: CGFloat = 2
    static let cardPadding: CGFloat = 8

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
