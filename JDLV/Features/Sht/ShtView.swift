import SwiftUI
import UIKit
import JDLVCore

//
//  ShtView.swift —— 98t 帖子列表（09 C 节 ShtScreen 逐字移植）。
//
//  结构：ListScaffold（骨架屏 2 列）内嵌 MovieGrid：viewMode 0=小图（手机 2 列 /
//  ≥600dp 3 列）或 1=大图（1 列）；卡片 key = tid（ShtCard 复用 UI/Common/Cards.swift）。
//  header（ShtHeader，随列表滚动）两行：搜索条独占整行 + 排序/筛选(徽标)/视图切换/导出；
//  footer = ListScaffold 集成的 LoadMoreFooter；右下角 ListNavTools。
//
//  筛选 sheet（C5 ModalBottomSheet 对位 .sheet + presentationDetents）：分类索引来源行
//  （「分类索引：远程库 · 更新于 HH:mm」+「刷新分类」）+「版区」卡 4 下拉（主版/副版/分类/
//  每页，级联 setMain 清 cat+type / setCat 清 type）+「开关与搜索模式」卡 3 chips
//  （仅看有磁力/模糊/语义互斥）+ 搜索提示 + 底部「完成」。
//
//  导出（C4）：Toast「导出中… (当前筛选范围)」→ vm.exportLinks() → 系统分享
//  （UIActivityViewControllerRepresentable；EXTRA_SUBJECT「98t 链接导出」/ Chooser 标题
//  「分享导出链接」在 iOS 由分享面板统一呈现，文本「导出 ${n} 条链接」随附件传递）+
//  Toast「✓ 已导出 ${n} 条链接」。
//

// MARK: - ShtView（VM 归属：外部注入或自持）

struct ShtView: View {
    private var externalVM: ShtVM?
    @StateObject private var ownedVM = ShtVM()

    init(vm: ShtVM? = nil) {
        self.externalVM = vm
    }

    var body: some View {
        if let vm = externalVM {
            ShtContent(vm: vm)
        } else {
            ShtContent(vm: ownedVM)
        }
    }
}

// MARK: - ShtContent

private struct ShtContent: View {
    @ObservedObject var vm: ShtVM

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var showFilter = false
    @State private var exportShare: ShtExportResult? = nil

    // MARK: 派生

    private var items: [Row] { vm.items ?? [] }
    private var itemsEmpty: Bool { items.isEmpty }

    /// 列数：viewMode 1(大图) → 1 列；0(小图) → 手机 2 列、最短边 ≥600（或 regular）3 列
    private var gridColumns: Int {
        if vm.viewMode != 0 { return 1 }
        let short = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return (short >= 600 || hSize == .regular) ? 3 : 2
    }

    /// footer note（C6）：derived 标注 +（updated 且 derived 未含「2 万」时追加）
    private var footerNote: String {
        guard vm.sort == "updated" else { return vm.derived }
        if vm.derived.contains("2 万") { return vm.derived }
        return vm.derived + " · 按更新时间排序：仅覆盖最近 2 万帖"   // 全角冒号
    }

    /// updated 自定义计数行（C6）：total>0 → 「已加载 n · 2 万帖窗口内共 t 条」；否则「已加载 n 条」
    private var updatedTotalLine: ((Int) -> String)? {
        guard vm.sort == "updated" else { return nil }
        return { [vm] n in
            vm.total > 0
                ? "已加载 \(n) · 2 万帖窗口内共 \(vm.total) 条"
                : "已加载 \(n) 条"
        }
    }

    // MARK: body

    var body: some View {
        ListScaffold(
            refreshing: vm.refreshing,
            onRefresh: { Task { await vm.refresh() } },
            firstLoading: vm.loading,
            empty: itemsEmpty,
            error: vm.error,
            onRetry: { Task { await vm.reload() } },
            emptyText: "远程 sehuatang 库暂无数据 (需抓取端上传或开启 mirror)",
            skeletonColumns: gridColumns,
            loadMore: LoadMoreConfig(
                loaded: items.count, total: vm.total, loadingMore: vm.loadingMore,
                approx: true, note: footerNote, hasMore: vm.hasMore,
                totalLine: updatedTotalLine,
                onLoadNext: { Task { await vm.loadNext() } }),
            showNavTools: true,
            pageLoaded: items.count,
            pageTotal: vm.total,
            pagePer: vm.per,
            goPage: { p in Task { await vm.goPage(p) } }
        ) {
            shtHeader
            if !itemsEmpty {
                grid
            }
        }
        .toolbar(.hidden, for: .navigationBar)   // 自绘 ShtHeader（对位 Android 无 TopAppBar）
        .sheet(isPresented: $showFilter) {
            ShtFilterSheet(vm: vm)
                .presentationDetents([.medium, .large])   // ModalBottomSheet 对位
        }
        .sheet(item: $exportShare) { r in
            // 系统分享（Intent.ACTION_SEND text/plain 对位）：文件 + 文本「导出 n 条链接」；
            // EXTRA_SUBJECT「98t 链接导出」/ Chooser 标题「分享导出链接」由分享面板统一承载
            ActivityShareSheet(activityItems: [r.url, "导出 \(r.count) 条链接"])
        }
        .onAppear {
            if vm.store == nil { vm.store = store }
            if vm.marks == nil { vm.marks = ShtMarkSource.default() }
            vm.onOpenSettings = { router.tab = "settings" }   // C5 语义未导入跳设置
            Task { await vm.bind(dataEpoch: store.dataEpoch) }
        }
        // 刷新结果 Toast（仅手动下拉路径写入；消费后清位）
        .onReceive(vm.refreshChannel.$value) { r in
            guard let r else { return }
            services.showToast(r.toastText)
            vm.refreshChannel.consume()
        }
    }

    // MARK: ShtHeader（随列表滚动两行）

    private var shtHeader: some View {
        VStack(spacing: 6) {
            // 第 1 行：搜索条独占整行（fillMaxWidth 对位）
            SearchBarCompact(
                text: Binding(get: { vm.queryState }, set: { vm.setQuery($0) }),
                placeholder: "搜索: 空格=且; 纯数字=按帖子ID",
                onSearch: { Task { await vm.search() } })   // 不 trim，Q 层自行 trim
                .accessibilityIdentifier("sht_searchbar")
            // 第 2 行（固定尺寸，从左到右）
            HStack(spacing: 8) {
                DropdownBox(
                    label: "排序",
                    options: [
                        DropdownOption(label: "发布日期", value: "date"),
                        DropdownOption(label: "最后更新", value: "updated"),
                    ],
                    current: vm.sort,
                    onSelect: { v in Task { await vm.setSort(v) } })
                filterButton
                ViewToggleButton(viewMode: vm.viewMode) { v in vm.setViewMode(v) }
                Spacer(minLength: 0)
                exportButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// 筛选入口：BadgedBox 徽标（filterCount>0）+ FilledTonalButton(36dp) = FilterList + 「筛选」
    private var filterButton: some View {
        Button {
            showFilter = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14))
                AppText("筛选", lvl: .meta)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: ComponentMetrics.chipHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(theme.accent.opacity(0.35), lineWidth: ComponentMetrics.cardStroke))
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if vm.filterCount > 0 {
                    AppText("\(vm.filterCount)", lvl: .meta, color: .white, fontWeight: .bold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accent))
                        .offset(x: 10, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sht_filter_button")
    }

    /// 导出 IconButton（48dp）：Share 图标，contentDescription「导出链接」
    private var exportButton: some View {
        Button {
            Task { await exportLinks() }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 18))
                .foregroundColor(theme.accent)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("导出链接")
        .accessibilityIdentifier("sht_export_button")
    }

    // MARK: 网格（卡片 key = tid；触底加载：倒数 3 项）

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: gridColumns),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(items.indices, id: \.self) { i in
                let t = items[i]
                ShtCard(
                    t: t,
                    coverUrl: vm.coverUrl(tid: t.s("tid"), row: t),
                    viewMode: vm.viewMode,
                    read: vm.readIds.contains(t.s("tid")),
                    fav: vm.favIds.contains(t.s("tid")),
                    onClick: { router.push(.shtThread(t.s("tid"))) }   // nav("sht/{tid}")
                )
                .onAppear {
                    if i >= items.count - 3 {
                        Task { await vm.loadNext() }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityIdentifier("sht_grid")
    }

    // MARK: 导出（C4 流程）

    private func exportLinks() async {
        services.showToast("导出中… (当前筛选范围)")
        if let r = await vm.exportLinks() {
            exportShare = r   // 成功 → 系统分享（✓ Toast 由 VM 发）
        }
    }
}

// MARK: - 筛选 sheet（C5：单 LazyColumn + 分区卡）

private struct ShtFilterSheet: View {
    @ObservedObject var vm: ShtVM
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sourceRow
                sectionCard("版区") { boardsCard }
                sectionCard("开关与搜索模式") { switchCard }
                AppText("搜索: 空格=且; 纯数字=按帖子ID; 模糊/语义二选一", lvl: .meta)
                doneButton
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.bg0.ignoresSafeArea())
    }

    // MARK: 分类索引来源行（catTs>0 → 更新于 HH:mm；右侧「刷新分类」TextButton 36dp）

    private var sourceRow: some View {
        HStack(spacing: 8) {
            AppText(
                vm.catTs > 0
                    ? "分类索引：远程库 · 更新于 \(Fmt.fmtTime(vm.catTs))"   // 全角冒号
                    : "分类索引：远程库",
                lvl: .meta)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await vm.loadCats(force: true) }
            } label: {
                AppText("刷新分类", lvl: .meta, color: theme.accent)
                    .frame(minHeight: ComponentMetrics.chipHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sht_refresh_cats")
        }
    }

    // MARK: 版区卡（4 下拉 FlowRow；级联：setMain 清 cat+type / setCat 清 type）

    private var boardsCard: some View {
        FlowLayout(spacing: 8) {
            DropdownBox(
                label: "主版", options: mainOptions, current: vm.main,
                onSelect: { v in Task { await vm.setMain(v) } })
            DropdownBox(
                label: "副版", options: subOptions, current: vm.cat,
                onSelect: { v in Task { await vm.setCat(v) } })
            DropdownBox(
                label: "分类", options: typeOptions, current: vm.type,
                onSelect: { v in Task { await vm.setType(v) } })
            DropdownBox(
                label: "每页", options: perOptions, current: "\(vm.per)",
                onSelect: { v in Task { await vm.setPer(Int(v) ?? 20) } })
        }
    }

    /// 主版：首项「全部」→"" + 各主版「name (count)」→name（C5 逐字）
    private var mainOptions: [DropdownOption] {
        [DropdownOption(label: "全部", value: "")] + vm.mains.map {
            DropdownOption(label: "\($0.s("name")) (\($0.i("c")))", value: $0.s("name"))
        }
    }

    /// 副版：「全部」+ subs（主版为空显示全部副版，否则过滤 sub.main == main）
    private var subOptions: [DropdownOption] {
        let list = vm.main.isEmpty ? vm.subs : vm.subs.filter { $0.s("main") == vm.main }
        return [DropdownOption(label: "全部", value: "")] + list.map {
            DropdownOption(label: $0.s("name"), value: $0.s("name"))
        }
    }

    /// 分类：「全部」+ types（副版为空显示全部，否则过滤 type.sub == cat）
    private var typeOptions: [DropdownOption] {
        let list = vm.cat.isEmpty ? vm.types : vm.types.filter { $0.s("sub") == vm.cat }
        return [DropdownOption(label: "全部", value: "")] + list.map {
            DropdownOption(label: $0.s("name"), value: $0.s("name"))
        }
    }

    /// 每页：20/40/60/80/100（写设置 shtPer）
    private var perOptions: [DropdownOption] {
        ["20", "40", "60", "80", "100"].map { DropdownOption(label: $0, value: $0) }
    }

    // MARK: 开关与搜索模式卡（AppToggleChip 选中加「✓ 」前缀由组件处理）

    private var switchCard: some View {
        FlowLayout(spacing: 8) {
            AppToggleChip(label: "仅看有磁力", selected: vm.hasMagnet) {
                Task { await vm.toggleMagnet() }
            }
            AppToggleChip(label: "模糊", selected: vm.fuzzy) {
                Task { await vm.toggleFuzzy() }
            }
            AppToggleChip(label: "语义", selected: vm.semantic) {
                Task { await vm.toggleSemantic() }
            }
        }
    }

    // MARK: 完成（≥48dp）

    private var doneButton: some View {
        Button {
            dismiss()
        } label: {
            AppText("完成", lvl: .bodyS, color: theme.accent, fontWeight: .medium,
                    textAlign: .center)
                .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.15)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    /// 分区卡（SectionCardSht 对位：标题 13sp primary Bold + 内容卡）
    private func sectionCard<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AppText(title, lvl: .bodyS, color: theme.accent, fontWeight: .bold)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner).fill(theme.bg1))
        .overlay(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner)
            .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
    }
}

// MARK: - 系统分享（UIActivityViewController Representable；C4 系统分享对位）

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
