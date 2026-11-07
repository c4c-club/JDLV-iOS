import SwiftUI

//
//  Chips.swift —— 设计系统 v2 选择 chip（13 §3.3：Capsule、44pt 触控、isSelected）。
//
//  与 Controls.AppToggleChip 的差异：Capsule 造型 + touchMin(44) 触控 + 无障碍
//  isSelected trait；横滚行（首页范围/资讯分类/TOP250 年份）与 FilterSheet 内使用。
//

struct SelectionChip: View {
    let label: String
    let selected: Bool
    var onToggle: () -> Void = {}

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 0) {
                AppText(selected ? "✓ \(label)" : label, lvl: .meta,
                        color: selected ? theme.accent : theme.text,
                        maxLines: 1,
                        fontWeight: selected ? .bold : .regular)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: ComponentMetrics.touchMin)
            .background(Capsule().fill(selected ? theme.accent.opacity(0.2) : theme.bg1))
            .overlay(Capsule()
                .stroke(selected ? theme.accent : theme.line,
                        lineWidth: selected ? 1.5 : ComponentMetrics.cardStroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 横滚 chip 行（首页范围 / 资讯分类 / TOP250 年份）：高 44、行内 spacing 8、页面边距 16。
struct ChipScrollRow: View {
    let items: [(label: String, value: String)]
    let current: String
    var onSelect: (String) -> Void
    /// 外层是否已有 ScrollView（false = 自带横向 ScrollView）
    var scrollable: Bool = true
    var rowId: String = ""

    var body: some View {
        let chips = ForEach(items.indices, id: \.self) { i in
            SelectionChip(label: items[i].label, selected: items[i].value == current) {
                onSelect(items[i].value)
            }
            .accessibilityIdentifier("\(rowId)_\(items[i].value)")
        }
        Group {
            if scrollable {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) { chips }
                        .padding(.horizontal, ComponentMetrics.pageMargin)
                }
            } else {
                LazyHStack(spacing: 8) { chips }
                    .padding(.horizontal, ComponentMetrics.pageMargin)
            }
        }
        .frame(minHeight: ComponentMetrics.touchMin)
    }
}
