import SwiftUI

/// R4 P5：自绘底栏避让（AppRoot 注入 56；详情页/push 页 0 或不读）
private struct TabBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 56
}

extension EnvironmentValues {
    var tabBarInset: CGFloat {
        get { self[TabBarInsetKey.self] }
        set { self[TabBarInsetKey.self] = newValue }
    }
}

//
//  PageNav.swift —— PageChip（跳页对话框）+ ListNavTools（右下角竖排导航）
//  （07 B17/B18、08 A.5、10 §0.4）。
//
//  PageChip：loaded<=0 不显示。Surface 圆角 14、surface 底、tonalElevation 3、
//  1pt outline 描边、padding 10h/6v。文案（Meta）：total>0 → 「{loaded} / {total}」；
//  否则「{loaded} / ?」（半角斜杠两侧空格）。点击弹跳页对话框：
//  - 标题「跳转页码」；正文（已知）「已加载 {loaded} / {total} · 共 {pages} 页 (每页 {per} 条)」
//    （pages = ceil(total/per)，全角「·」+半角括号）；（未知）「已加载 {loaded} 条 ·
//    总数未知 (每页 {per} 条), 可直接输入页码」（半角逗号+空格）；
//  - 输入框 placeholder「输入页码」（仅数字）；按钮「跳转」（p>=1 才回调，上界由 VM 钳制）/「取消」。
//
//  ListNavTools：右下角竖排（padding end 12 bottom 16）：上方 PageChip；下方回顶 FAB
//  （primary 底、「↑」白 Bold 16pt；滚动超过约 3 行淡入，点击回顶）。
//

/// 页码 chip（含跳页对话框；loaded<=0 整体不渲染）。
struct PageChip: View {
    let loaded: Int
    let total: Int64
    var per: Int = 40
    var goPage: ((Int) -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var showJump = false
    @State private var pageInput = ""
    @State private var jumpError = ""

    /// 页码上界：total > 0 → ceil(total/per)；未知 total 只钳下限（§8.4）
    private var maxPage: Int? {
        total > 0 ? Int(ceil(Double(total) / Double(max(per, 1)))) : nil
    }

    var body: some View {
        // R4 P5：loaded>0 || total>0 即渲染（首屏加载中也有跳页入口）
        if loaded > 0 || total > 0 {
            Button {
                pageInput = ""
                jumpError = ""
                showJump = true
            } label: {
                AppText(AppCopy.pageChipLabel(loaded: loaded, total: total), lvl: .meta)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 14).fill(theme.bg1))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page_chip")
            .sheet(isPresented: $showJump) { jumpSheet }
        }
    }

    // MARK: 跳页对话框（sheet + presentationDetents）

    private var jumpSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppText(AppCopy.pageJumpTitle, lvl: .titleM)
            AppText(total > 0
                    ? AppCopy.pageJumpBodyKnown(loaded: loaded, total: total, per: per)
                    : AppCopy.pageJumpBodyUnknown(loaded: loaded, per: per),
                    lvl: .meta)
            TextField(AppCopy.pageJumpPlaceholder, text: $pageInput)
                .keyboardType(.numberPad)
                .font(.system(size: 14))
                .foregroundColor(theme.text)
                .padding(.horizontal, 10)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                .accessibilityIdentifier("page_jump_field")
            // R4 P5：越界/非法输入保持 sheet 并提示（§8.4）
            if !jumpError.isEmpty {
                AppText(jumpError, lvl: .meta, color: theme.red)
            }
            HStack(spacing: 12) {
                Button {
                    showJump = false
                } label: {
                    AppText(AppCopy.pageJumpCancel, lvl: .bodyS, color: theme.text2)
                        .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.bg2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("page_jump_cancel")
                Button {
                    if let p = Int(pageInput.trimmingCharacters(in: .whitespaces)),
                       p >= 1, maxPage == nil || p <= maxPage! {
                        goPage?(p)
                        showJump = false
                    } else {
                        jumpError = AppCopy.pageJumpOutOfRange
                    }
                } label: {
                    AppText(AppCopy.pageJumpGo, lvl: .bodyS, color: .white, fontWeight: .medium)
                        .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("page_jump_go")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg1.ignoresSafeArea())
        .presentationDetents([.height(280)])
    }
}

/// 右下角竖排：PageChip + 回顶 FAB（在 ListScaffold 内以 overlay(alignment: .bottomTrailing) 挂载）。
struct ListNavTools: View {
    var loaded: Int
    var total: Int64 = -1
    var per: Int = 40
    var goPage: ((Int) -> Void)? = nil
    /// 滚动超过约 3 行 → true（ListScaffold 由 offset 推导）
    var showScrollTop: Bool
    /// R4 P5：底部避让（TabBar 页 = 56；详情 = 0）——PageChip/FAB 不再被自绘 TabBar 遮挡
    var bottomInset: CGFloat = 0
    var onScrollTop: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            PageChip(loaded: loaded, total: total, per: per, goPage: goPage)
            if showScrollTop {
                Button {
                    onScrollTop()
                } label: {
                    AppText(AppCopy.scrollTopIcon, lvl: .body, color: .white, fontWeight: .bold)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(theme.accent))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityIdentifier("scroll_top")
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, bottomInset + 16)
        .animation(.easeInOut(duration: 0.2), value: showScrollTop)
    }
}
