import SwiftUI
import JDLVCore

//
//  FavsView.swift —— 收藏页（10 §7 FavsScreen 对位 + 13 §4.12 设计系统 v2）。
//
//  v2（问题 11）：navigationTitle("收藏") + Picker(.segmented) 三 tab（影片/帖子/女优，
//  文案带数量）→ List 行卡 + swipeActions 删除（R3：FavsVM.remove → 取消收藏 + reload）+
//  .refreshable；导出收藏 → toolbar。loading → LoadingBox；空 → EmptyBox「暂无收藏 —
//  在详情页点 ☆ 收藏」。点击路由：movie → movie/{id}；sht → sht/{tid}；actor → actor/{id}。
//  导出：文本组装（逐字格式）→ 系统分享面板（ActivityShareSheet 复用 ShtView 同模块实现）。
//

struct FavsView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @Environment(\.appTheme) private var theme

    @StateObject private var vm: FavsVM
    @State private var tab = "movie"          // 默认选中 0（影片）
    @State private var showExportShare: Bool = false
    @State private var exportPayload: String = ""

    init() {
        _vm = StateObject(wrappedValue: FavsVM.makeDefault())
    }

    private var rows: [Row] { vm.rows(tab) }

    var body: some View {
        Group {
            if vm.loading {
                LoadingBox()
            } else {
                listContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    exportPayload = vm.exportText()
                    showExportShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityIdentifier("favs_export")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { tabBar }
        .onAppear { Task { await vm.reload() } }   // bind 即 reload（不随 dataEpoch 自动刷新）
        .sheet(isPresented: $showExportShare) {
            // ACTION_SEND text/plain 对位（chooser 标题「导出收藏」由系统面板承载）
            ActivityShareSheet(activityItems: [exportPayload])
        }
        .accessibilityIdentifier("tab_root_favs")
    }

    // MARK: Tab（Picker .segmented 三 tab，文案带数量）

    private var tabBar: some View {
        Picker("收藏分类", selection: $tab) {
            ForEach(Array(FavsCopy.tabs.enumerated()), id: \.offset) { _, t in
                Text(FavsCopy.tabLabel(t.label, vm.count(t.kind))).tag(t.kind)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, ComponentMetrics.pageMargin)
        .padding(.vertical, 6)
        .background(theme.bg0)
        .accessibilityIdentifier("favs_tabs")
    }

    // MARK: 内容区（List 行卡 + swipeActions 删除 + .refreshable）

    private var listContent: some View {
        Group {
            if let err = vm.error {
                // R4 P9：读取失败显式态（与空收藏区分；可重试）
                ErrorBox(text: err, onRetry: { Task { await vm.reload() } })
            } else if rows.isEmpty {
                EmptyBox(text: FavsCopy.emptyText)
            } else {
                List {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        FavRowCard(row: r) {
                            tap(r)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await vm.remove(r) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await vm.reload() }
            }
        }
    }

    /// 点击路由（10 §7.2）：movie → movie/{id}；sht → sht/{tid}；否则 actor/{id}
    private func tap(_ r: Row) {
        switch r.s("kind") {
        case "movie": router.push(.movie(r.s("id")))
        case "sht": router.push(.shtThread(r.s("id")))
        default: router.push(.actor(r.s("id")))
        }
    }
}

// MARK: - FavRowCard（行卡：标题 13pt Medium 2 行 + 时间 12pt 上 4pt）

struct FavRowCard: View {
    let row: Row
    var onClick: () -> Void

    @Environment(\.appTheme) private var theme

    private var timeText: String {
        FavsVM.rowTime(row) ?? FavsCopy.unknownTime
    }

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                AppText(FavsVM.rowTitle(row), lvl: .bodyS,
                        maxLines: 2, textAlign: .leading, fontWeight: .medium)
                AppText(timeText, lvl: .meta, color: theme.text2)
                    .padding(.top, 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome()
        .accessibilityIdentifier("fav_row")
    }
}
