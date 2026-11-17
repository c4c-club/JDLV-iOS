import SwiftUI

//
//  CardGrid.swift —— 设计系统 v2 统一网格（13 §2.6/§3.3：等宽等高 + 最后一行占位）。
//
//  纯逻辑 GridMath 可单测（GridRowsTests / CardLayoutTests）：
//  - cellWidth(pageWidth:columns:) = (W - 2*margin - (N-1)*spacing) / N
//  - chunk(items:columns:) 行分块，最后一行不足用 nil 占位保证左对齐。
//
//  视图：CardGrid = LazyVGrid（固定列宽 GridItem(.fixed)）+ ForEach(items) cell 级懒加载；
//  每个 cell 固定 frame(cellW, cardH)，spacing = gridSpacing。
//  R7 P2：旧 chunk 行实现（lazy 标志 + 全量 ForEach 所有行）退役 —— 单层懒加载
//  （硬规则 7）：网格页 PageScaffold 传 contentLazy:false（外层普通 VStack），
//  LazyVGrid 是唯一懒容器，滚动只构建可见 cell；空位左对齐由 Grid 列布局天然保证。
//  GridMath.chunk 保留（GridRowsTests / CardLayoutTests 单测依赖）。
//

// MARK: - 纯布局数学（可单测）

/// 容器宽度环境（PageScaffold 注入；页面计算 cellW 用，禁 UIScreen.main.bounds）。
private struct ContainerWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var containerWidth: CGFloat {
        get { self[ContainerWidthKey.self] }
        set { self[ContainerWidthKey.self] = newValue }
    }
}

/// 页面侧取容器宽度：注入值 > 0 用之；否则回退水平 size class 估算（首帧兜底）。
/// R4 P3：删除 393 硬编码 —— compact 首帧兜底改 320（最小机型；宁可窄不可溢出）。
func resolvedContainerWidth(_ envWidth: CGFloat, hSize: UserInterfaceSizeClass?) -> CGFloat {
    if envWidth > 0 { return envWidth }
    return hSize == .regular ? 768 : 320
}

/// R6 PHASE3：容器宽读取（环境向下通道）。
/// PageScaffold 在 ScrollView 子树注入 environment(\.containerWidth)，本读取器放进
/// content 即取到实测宽（首帧即真值）。替代 R4 的页面级 PageContainerWidthKey 冒泡
/// （R5 CI 截图实证失效：402pt 屏恒走 320 兜底 → 浏览/女优/98t 右侧 ~82pt 空白）。
struct ContainerWidthReader<Content: View>: View {
    @Environment(\.containerWidth) private var envWidth
    @Environment(\.horizontalSizeClass) private var hSize
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        content(resolvedContainerWidth(envWidth, hSize: hSize))
    }
}

enum GridMath {
    /// 列宽公式：cellW = (W - 2*margin - (N-1)*spacing) / N（13 §3.4）
    static func cellWidth(pageWidth: CGFloat, columns: Int,
                          margin: CGFloat = ComponentMetrics.pageMargin,
                          spacing: CGFloat = ComponentMetrics.gridSpacing) -> CGFloat {
        guard pageWidth > 0, columns >= 1 else { return 0 }
        let usable = pageWidth - 2 * margin - CGFloat(columns - 1) * spacing
        return max(0, usable / CGFloat(columns))
    }

    /// 行分块：每行 columns 个；最后一行不足用 nil 占位（Color.clear）保证左对齐。
    static func chunk<T>(_ items: [T], columns: Int) -> [[T?]] {
        guard columns >= 1 else { return items.map { [$0] } }
        var rows: [[T?]] = []
        var i = 0
        while i < items.count {
            let end = min(i + columns, items.count)
            var row: [T?] = []
            for k in i..<end { row.append(items[k]) }   // 逐个 append（显式 T -> T?）
            while row.count < columns { row.append(nil) }
            rows.append(row)
            i = end
        }
        return rows
    }
}

// MARK: - CardGrid 视图

struct CardGrid<Item, Cell: View>: View {
    let items: [Item]
    let columns: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// R7 P2：true（默认）= LazyVGrid cell 级懒加载；false = 普通 VStack（全量，仅诊断用）
    var useLazyGrid: Bool = true
    /// 外层 wrapper 的 accessibility 前缀（"card_browse" → card_browse_0…；
    /// 打在含固定 frame 的 wrapper 上 —— LayoutAudit 读到的 frame = cellW×cellH 精确值）
    var idPrefix: String = ""
    @ViewBuilder var cell: (Item) -> Cell

    /// 固定列宽（GridItem(.fixed)）—— 布局审计 frame 精确值不受容器宽度抖动影响
    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.fixed(cellWidth), spacing: ComponentMetrics.gridSpacing),
              count: columns)
    }

    var body: some View {
        if useLazyGrid {
            LazyVGrid(columns: gridItems, alignment: .leading,
                      spacing: ComponentMetrics.gridSpacing) {
                gridCells
            }
        } else {
            VStack(alignment: .leading, spacing: ComponentMetrics.gridSpacing) {
                gridCells
            }
        }
    }

    @ViewBuilder
    private var gridCells: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
            ZStack {
                cell(item)
            }
            .frame(width: cellWidth, height: cellHeight, alignment: .top)
            // 显式 a11y 容器（children: .contain）—— 保证 XCUI 以 card_<page>_<idx>
            // 查询到精确 cellW×cellH 的 wrapper frame（Group+identifier 不保证成节点）
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(idPrefix.isEmpty ? "" : "\(idPrefix)_\(idx)")
        }
    }
}
