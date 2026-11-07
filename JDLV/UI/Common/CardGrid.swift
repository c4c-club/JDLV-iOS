import SwiftUI

//
//  CardGrid.swift —— 设计系统 v2 统一网格（13 §2.6/§3.3：等宽等高 + 最后一行占位）。
//
//  纯逻辑 GridMath 可单测（GridRowsTests / CardLayoutTests）：
//  - cellWidth(pageWidth:columns:) = (W - 2*margin - (N-1)*spacing) / N
//  - chunk(items:columns:) 行分块，最后一行不足用 nil 占位保证左对齐。
//
//  视图：CardGrid = LazyVStack（或普通 VStack）+ HStack(alignment:.top) 行；
//  每个 cell 固定 frame(cellW, cardH)，行内 spacing = gridSpacing，
//  行间 spacing = gridSpacing；空位补 Color.clear。
//
//  无嵌套 lazy 契约（13 §3.1 原则 6）：PageScaffold 的 content 已是 LazyVStack，
//  页面网格用 `lazy: false`（默认）的普通 VStack 行 —— LazyVStack 的直接子项是
//  HStack 行，行内不再嵌 lazy 容器；独立使用（无外层 lazy）时可传 lazy: true。
//

// MARK: - 纯布局数学（可单测）

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
            var row: [T?] = Array(items[i..<end])
            if row.count < columns {
                row.append(contentsOf: Array(repeating: nil, count: columns - row.count))
            }
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
    /// true = 内部 LazyVStack（独立顶层使用）；false = 普通 VStack（PageScaffold content 内）
    var lazy: Bool = false
    @ViewBuilder var cell: (Item) -> Cell

    var body: some View {
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: ComponentMetrics.gridSpacing) {
                    rows
                }
            } else {
                VStack(alignment: .leading, spacing: ComponentMetrics.gridSpacing) {
                    rows
                }
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        let chunked = GridMath.chunk(items, columns: columns)
        ForEach(chunked.indices, id: \.self) { r in
            HStack(alignment: .top, spacing: ComponentMetrics.gridSpacing) {
                ForEach(chunked[r].indices, id: \.self) { c in
                    if let item = chunked[r][c] {
                        cell(item)
                            .frame(width: cellWidth, height: cellHeight, alignment: .top)
                    } else {
                        Color.clear
                            .frame(width: cellWidth, height: cellHeight)
                    }
                }
            }
        }
    }
}
