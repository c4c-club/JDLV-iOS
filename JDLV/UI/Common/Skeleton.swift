import SwiftUI

//
//  Skeleton.swift —— 骨架屏（07 B4）。
//
//  - SkeletonGrid(columns, rows)：外层 padding 8h/8v；每行 Row(height 180, padding v6)；
//    每格 padding h6、圆角 10、背景 surfaceVariant(theme.bg3)；alpha 呼吸动画
//    0.25 → 0.55，tween 700ms LinearEasing 无限循环。
//  - FirstLoadSkeleton(loading, hasItems, columns)：loading && !hasItems 时显示骨架
//    （数据到位不跳动、不闪白）——ListScaffold 的 firstLoading && empty 分支即此语义。
//  - SkeletonBars(n)：3 根 24pt 高圆角灰条（浏览筛选面板索引未到位占位，08 A.3）。
//

/// 骨架网格（ListScaffold 首载态；资讯/热评 1 列、浏览/搜索/98t/TOP250 2 列、女优 3 列）。
struct SkeletonGrid: View {
    var columns: Int = 2
    var rows: Int = 5

    @Environment(\.appTheme) private var theme
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<max(1, rows), id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0..<max(1, columns), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner)
                            .fill(theme.bg3)
                            .opacity(pulse ? ComponentMetrics.skeletonAlphaMax
                                            : ComponentMetrics.skeletonAlphaMin)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: ComponentMetrics.skeletonRowHeight)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.linear(duration: ComponentMetrics.skeletonAnimDuration)
                .repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// FirstLoadSkeleton 语义内联（07 B4）：loading && !hasItems 才出骨架。
struct FirstLoadSkeleton: View {
    let loading: Bool
    let hasItems: Bool
    var columns: Int = 2

    var body: some View {
        if loading && !hasItems {
            SkeletonGrid(columns: columns)
        }
    }
}

/// 骨架条（浏览筛选面板：索引未到位时 3 根 24pt 圆角灰条）。
struct SkeletonBars: View {
    var bars: Int = 3
    var barHeight: CGFloat = 24

    @Environment(\.appTheme) private var theme
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<max(1, bars), id: \.self) { i in
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.bg3)
                    .opacity(pulse ? ComponentMetrics.skeletonAlphaMax
                                   : ComponentMetrics.skeletonAlphaMin)
                    .frame(height: barHeight)
                    .frame(maxWidth: i == bars - 1 ? 160 : .infinity, alignment: .leading)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: ComponentMetrics.skeletonAnimDuration)
                .repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
