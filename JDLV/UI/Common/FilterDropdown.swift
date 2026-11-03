import SwiftUI

//
//  FilterDropdown.swift —— 顶部下拉弹层 + 折叠分区（07 B22/B23）。
//
//  FilterDropdown（替代底部 ModalBottomSheet，解决输入法顶走 sheet）：
//  - 全屏 overlay：点外关闭；外层 fillMaxWidth + 键盘避让 + padding 12h/8v。
//  - Card 圆角 14、1pt line 描边、bg1 底、heightIn(max = 屏高 × 0.62)。
//  - 铁律：内容区只允许单一 LazyColumn（禁内层竖向 ScrollView、禁在底部 sheet 放输入控件）
//    —— 由调用方保证，本组件只提供容器。
//
//  CollapsibleSection（B23）：
//  - 标题行 minHeight 48 可点（无涟漪）：title BodyS accent Bold weight(1) +
//    右侧 chevron.up(展开)/chevron.down(收起) 20pt text2。
//  - 内容 AnimatedVisibility（opacity + move(edge:.top) 对位 expandVertically）；
//    收起时内容不 compose（性能 + 默认全收起）。
//  - 折叠记忆：storageKey 非空时展开态落 UserDefaults（键前缀 jdlv_collapse_）。
//

// MARK: - FilterDropdown（B22：顶部下拉弹层容器）

enum FD {
    static let keyPrefix = "jdlv_collapse_"
}

struct FilterDropdown<Content: View>: View {
    var expanded: Bool
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            if expanded {
                ZStack(alignment: .top) {
                    // 点外关闭（近透明底，不遮挡感知但可命中）
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { onDismiss() }
                    panel(maxHeight: geo.size.height * 0.62)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(99)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }

    private func panel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.bg1))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

// MARK: - CollapsibleSection（B23：折叠分区 + 折叠记忆）

struct CollapsibleSection<Content: View>: View {
    let title: String
    /// 非空时展开态持久化（折叠记忆；键 = jdlv_collapse_{storageKey}）
    var storageKey: String? = nil
    /// 无记忆时的初始态（默认全收起）
    var initiallyExpanded: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.appTheme) private var theme
    @State private var expanded = false
    @State private var hydrated = false


    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
                persist()
            } label: {
                HStack(spacing: 0) {
                    AppText(title, lvl: .bodyS, color: theme.accent, fontWeight: .bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 20))
                        .foregroundColor(theme.text2)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: ComponentMetrics.buttonMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 收起时内容不 compose（性能 + 默认全收起）
            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .onAppear {
            guard !hydrated else { return }
            hydrated = true
            expanded = savedValue() ?? initiallyExpanded
        }
    }

    private func savedValue() -> Bool? {
        guard let key = storageKey else { return nil }
        return UserDefaults.standard.object(forKey: FD.keyPrefix + key) as? Bool
    }

    private func persist() {
        guard let key = storageKey else { return }
        UserDefaults.standard.set(expanded, forKey: FD.keyPrefix + key)
    }
}
