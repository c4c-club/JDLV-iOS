import SwiftUI
import JDLVCore

//
//  LookupView.swift —— 反查结果页（10 §6.2 LookupScreen 逐字移植）。
//
//  - 压栈路由 lookup?payload=<Base64(JSON(Filters 12 字段)+label+sort)>，每次点击压一层、
//    返回逐层回详情（Router.push(.lookup(payload))；绝不 popBackStack 弹掉详情页）。
//  - 顶栏 Row（最小高 48）：返回 IconButton（contentDescription「返回」）+ label 文本
//    （15pt，1 行省略；label 默认「反查」）+ ✕ 关闭按钮（pop，P9b 任务 D）。
//  - 主体：spec == nil → EmptyBox「反查参数无效」/「按返回键重试」（🗂 图标）；
//    否则 BrowseView(embedded=true, skipBind=true) 完整复用浏览页 UI
//    （tab/筛选/网格/翻页），先 vm.applyFilters(spec.filters, spec.sort)。
//  - 独立 VM：LookupVM 自持 BrowseVM 实例（筛选状态互不污染）。
//

struct LookupView: View {
    let payload: String
    @StateObject private var vm: LookupVM

    @EnvironmentObject private var router: Router
    @Environment(\.appTheme) private var theme

    init(payload: String) {
        self.payload = payload
        _vm = StateObject(wrappedValue: LookupVM(payload: payload))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if vm.spec == nil {
                // 解码失败兜底空态（两条文案逐字）
                EmptyBox(text: AppCopy.lookupInvalid, hint: AppCopy.lookupInvalidHint)
            } else {
                BrowseView(embedded: true, skipBind: true, vm: vm.browseVM)
            }
        }
        .background(theme.bg0.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.applyOnce() }   // embedded/skipBind：首次 applyFilters（恒一次）
        .accessibilityIdentifier("secondary_page")
    }

    // MARK: 顶栏（返回 + label 15pt 1 行省略 + ✕ 关闭；Row 最小高 48）

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                router.pop()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20))
                    .foregroundColor(theme.text)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            AppText(vm.label, lvl: .body, maxLines: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                router.pop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15))
                    .foregroundColor(theme.text2)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 48)
    }
}
