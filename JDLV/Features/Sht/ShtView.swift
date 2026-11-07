import SwiftUI
import UIKit
import JDLVCore

//
//  ShtView.swift —— 98t 帖子列表（09 C 节 ShtScreen 对位 + 13 §4.6 设计系统 v2）。
//
//  v2（问题 7/11）：PageScaffold（单 ScrollView + 单 LazyVStack + .refreshable +
//  overlay 页码）内嵌 CardGrid（等宽等高 + 最后一行占位）；navigationTitle("98t") +
//  toolbar：排序 Menu、视图 Menu、筛选（badge）→ .sheet、导出 ShareLink。
//  FilterSheet：Form + Section（版区：主版/副版/分类 Picker 级联 + 每页 Picker；
//  开关：仅看磁力/模糊/语义 Toggle）+ 重置/完成（setMain 清 cat+type / setCat 清 type）。
//
//  导出（C4）：Toast「导出中… (当前筛选范围)」→ vm.exportLinks() → 系统分享 +
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
    @Environment(\.containerWidth) private var envWidth

    @State private var showFilter = false
    @State private var exportShare: ShtExportResult? = nil

    // MARK: 派生

    private var items: [Row] { vm.items ?? [] }
    private var itemsEmpty: Bool { items.isEmpty }
    private var pageWidth: CGFloat { resolvedContainerWidth(envWidth, hSize: hSize) }

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
        PageScaffold(
            onRefresh: { await vm.refresh() },
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
            searchBar
            if !itemsEmpty {
                grid
            }
        }
        .navigationTitle("98t")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { shtToolbar }
        .sheet(isPresented: $showFilter) {
            ShtFilterSheet(vm: vm)
                .presentationDetents([.medium, .large])   // ModalBottomSheet 对位
        }
        .sheet(item: $exportShare) { r in
            // 系统分享（Intent.ACTION_SEND text/plain 对位）：文件 + 文本「导出 n 条链接」
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
        .accessibilityIdentifier("sht_page")
    }

    // MARK: toolbar（排序/视图 Menu + 筛选 badge + 导出）

    @ToolbarContentBuilder
    private var shtToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    Task { await vm.setSort("date") }
                } label: {
                    if vm.sort == "date" { Label("发布日期", systemImage: "checkmark") }
                    else { Text("发布日期") }
                }
                Button {
                    Task { await vm.setSort("updated") }
                } label: {
                    if vm.sort == "updated" { Label("最后更新", systemImage: "checkmark") }
                    else { Text("最后更新") }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("sht_sort_menu")

            Button {
                showFilter = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .overlay(alignment: .topTrailing) {
                        if vm.filterCount > 0 {
                            Text("\(vm.filterCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.accent))
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .accessibilityIdentifier("sht_filter_button")

            Menu {
                Button { vm.setViewMode(0) } label: {
                    if vm.viewMode == 0 { Label(AppCopy.viewSmall, systemImage: "checkmark") }
                    else { Text(AppCopy.viewSmall) }
                }
                Button { vm.setViewMode(1) } label: {
                    if vm.viewMode == 1 { Label(AppCopy.viewLarge, systemImage: "checkmark") }
                    else { Text(AppCopy.viewLarge) }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .accessibilityIdentifier("sht_view_menu")

            Button {
                Task { await exportLinks() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("导出链接")
            .accessibilityIdentifier("sht_export_button")
        }
    }

    // MARK: 搜索条（随列表滚动；「不 trim，Q 层自行 trim」）

    private var searchBar: some View {
        SearchBarCompact(
            text: Binding(get: { vm.queryState }, set: { vm.setQuery($0) }),
            placeholder: "搜索: 空格=且; 纯数字=按帖子ID",
            onSearch: { Task { await vm.search() } })
            .accessibilityIdentifier("sht_searchbar")
            .padding(.top, 6)
    }

    // MARK: 网格（CardGrid 等宽等高；卡片 key = tid；触底加载：倒数 3 项）

    private var grid: some View {
        let cols = gridColumns
        let cellW = GridMath.cellWidth(pageWidth: pageWidth, columns: cols)
        let cardH = vm.viewMode == 1
            ? CardLayout.shtLargeH(cellW: cellW)
            : CardLayout.shtSmallH(cellW: cellW)
        return CardGrid(items: items.indices.map { ($0, items[$0]) },
                        columns: cols, cellWidth: cellW, cellHeight: cardH) { pair in
            let (i, t) = pair
            return ShtCard(
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
        .padding(.horizontal, ComponentMetrics.pageMargin)
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

// MARK: - 筛选 sheet（13 §4.6：Form + Section + Picker 级联 + Toggle + 重置/完成）

private struct ShtFilterSheet: View {
    @ObservedObject var vm: ShtVM
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section("分类索引") {
                    HStack(spacing: 8) {
                        Text(vm.catTs > 0
                             ? "远程库 · 更新于 \(Fmt.fmtTime(vm.catTs))"   // 全角冒号
                             : "远程库")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                        Button("刷新分类") {
                            Task { await vm.loadCats(force: true) }
                        }
                        .font(.system(size: 13))
                        .accessibilityIdentifier("sht_refresh_cats")
                    }
                }
                Section("版区") {
                    Picker("主版", selection: mainBinding) {
                        Text("全部").tag("")
                        ForEach(vm.mains.indices, id: \.self) { i in
                            Text("\(vm.mains[i].s("name")) (\(vm.mains[i].i("c")))")
                                .tag(vm.mains[i].s("name"))
                        }
                    }
                    .accessibilityIdentifier("sht_main_picker")
                    Picker("副版", selection: subBinding) {
                        Text("全部").tag("")
                        ForEach(subList.indices, id: \.self) { i in
                            Text(subList[i].s("name")).tag(subList[i].s("name"))
                        }
                    }
                    Picker("分类", selection: typeBinding) {
                        Text("全部").tag("")
                        ForEach(typeList.indices, id: \.self) { i in
                            Text(typeList[i].s("name")).tag(typeList[i].s("name"))
                        }
                    }
                    Picker("每页", selection: perBinding) {
                        ForEach(["20", "40", "60", "80", "100"], id: \.self) { p in
                            Text(p).tag(p)
                        }
                    }
                }
                Section("开关与搜索模式") {
                    Toggle("仅看有磁力", isOn: magnetBinding)
                    Toggle("模糊", isOn: fuzzyBinding)
                    Toggle("语义", isOn: semanticBinding)
                }
                Section {
                    Text("搜索: 空格=且; 纯数字=按帖子ID; 模糊/语义二选一")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Section {
                    Button("重置") {
                        Task { await vm.clearFilters() }
                    }
                    .accessibilityIdentifier("sht_filter_reset")
                }
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("sht_filter_done")
                }
            }
        }
    }

    // MARK: 级联绑定（setMain 清 cat+type / setCat 清 type 由 VM 承担）

    private var mainBinding: Binding<String> {
        Binding(get: { vm.main }, set: { v in Task { await vm.setMain(v) } })
    }
    private var subBinding: Binding<String> {
        Binding(get: { vm.cat }, set: { v in Task { await vm.setCat(v) } })
    }
    private var typeBinding: Binding<String> {
        Binding(get: { vm.type }, set: { v in Task { await vm.setType(v) } })
    }
    private var perBinding: Binding<String> {
        Binding(get: { "\(vm.per)" }, set: { v in Task { await vm.setPer(Int(v) ?? 20) } })
    }
    private var magnetBinding: Binding<Bool> {
        Binding(get: { vm.hasMagnet }, set: { _ in Task { await vm.toggleMagnet() } })
    }
    private var fuzzyBinding: Binding<Bool> {
        Binding(get: { vm.fuzzy }, set: { _ in Task { await vm.toggleFuzzy() } })
    }
    private var semanticBinding: Binding<Bool> {
        Binding(get: { vm.semantic }, set: { _ in Task { await vm.toggleSemantic() } })
    }

    /// 副版：主版为空显示全部副版，否则过滤 sub.main == main
    private var subList: [Row] {
        vm.main.isEmpty ? vm.subs : vm.subs.filter { $0.s("main") == vm.main }
    }
    /// 分类：副版为空显示全部，否则过滤 type.sub == cat
    private var typeList: [Row] {
        vm.cat.isEmpty ? vm.types : vm.types.filter { $0.s("sub") == vm.cat }
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
