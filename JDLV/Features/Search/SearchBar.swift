import SwiftUI
import JDLVCore

//
//  SearchBar.swift —— 搜索条 + 范围/模式/历史 chips（07 B24、C2、C3、C7）。
//
//  - SearchBarCompact：外层 Row(padding 12h/4v, spacedBy 8) → 输入区 44pt 高 + 圆角 22 +
//    36pt 清除钮（S11-P1 压矮定稿值，勿回退 56/68）；placeholder 逐字
//    「番号 / 标题 / 女优 / 标签…」；回车触发 onSearch；清除钮 contentDescription「清除」。
//  - ScopeChipsRow：7 范围 chips 一行横滚（综合/番号/字头/标题/女优/标签/系列，36pt），
//    选中即切 scope（立即重搜由 VM setScope 完成）。
//  - MatchViewRow：精确/模糊 AppToggleChip 两选一 + 4pt + ViewToggleButton（B9）。
//  - HistoryChipsRow：SuggestionChip 12sp 横滚（历史词原样），点击即搜。
//

// MARK: - SearchBarCompact（B24；总占高约 52pt = 44 + 上下 4pt padding）

struct SearchBarCompact: View {
    @Binding var text: String
    var placeholder: String = SearchCopy.searchPlaceholder
    var onSearch: () -> Void = {}

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(theme.text2)
                TextField(placeholder, text: $text)
                    .font(.system(size: 14))
                    .foregroundColor(theme.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(onSearch)
                    // TextField 本体 id（容器 id 会触发 SwiftUI a11y 合并、子字段不再暴露）
                    .accessibilityIdentifier("home_search_field")
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16))
                            .foregroundColor(theme.text2)
                            .frame(width: ComponentMetrics.searchClearButton,
                                   height: ComponentMetrics.searchClearButton)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)   // clickableNoRipple
                    .accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: ComponentMetrics.searchBarHeight)
            .background(RoundedRectangle(cornerRadius: ComponentMetrics.searchBarRadius)
                .fill(theme.bg3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityIdentifier("home_searchbar")
    }
}

// MARK: - 范围 chips（C2：综合/番号/字头/标题/女优/标签/系列；FilterChip 12sp → 36pt chip）

struct ScopeChipsRow: View {
    let current: String
    var onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SearchCopy.scopes, id: \.value) { sc in
                    AppToggleChip(label: sc.label, selected: current == sc.value) {
                        onSelect(sc.value)
                    }
                    .accessibilityIdentifier("scope_\(sc.value)")
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - 匹配模式 + 视图开关（C2.3：精确/模糊两选一 + ViewToggleButton）

struct MatchViewRow: View {
    let mode: String            // "exact" / "fuzzy"
    let viewMode: Int
    var onMode: (String) -> Void
    var onView: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            AppToggleChip(label: SearchCopy.modeExact, selected: mode == "exact") {
                onMode("exact")
            }
            .accessibilityIdentifier("mode_exact")
            AppToggleChip(label: SearchCopy.modeFuzzy, selected: mode == "fuzzy") {
                onMode("fuzzy")
            }
            .accessibilityIdentifier("mode_fuzzy")
            Spacer(minLength: 4)
            ViewToggleButton(viewMode: viewMode, onToggle: onView)
                .accessibilityIdentifier("view_toggle")
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - 搜索历史 chips（C7：SuggestionChip 12sp，文案=历史词原样）

struct HistoryChipsRow: View {
    let items: [String]
    var onPick: (String) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { h in
                    Button {
                        onPick(h)
                    } label: {
                        AppText(h, lvl: .meta, maxLines: 1)
                            .padding(.horizontal, 10)
                            .frame(height: ComponentMetrics.chipHeight)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg1))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history_\(h)")
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - 资讯/热评入口 chips（C2.5：两枚 FilterChip 各 weight(1)）

struct HomeEntriesRow: View {
    var onArticles: () -> Void
    var onHotReviews: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            entryChip(SearchCopy.entriesArticles, id: "entry_articles", action: onArticles)
            entryChip(SearchCopy.entriesHotReviews, id: "entry_hotreviews", action: onHotReviews)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func entryChip(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppText(label, lvl: .meta, textAlign: .center)
                .frame(maxWidth: .infinity, minHeight: ComponentMetrics.chipHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg1))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
