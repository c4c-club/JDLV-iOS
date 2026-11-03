import SwiftUI
import JDLVCore

//
//  FavsView.swift —— 收藏页（10 §7 FavsScreen 移植；底部导航 tab「收藏」）。
//
//  结构（本页未包 ListScaffold，无下拉刷新）：顶部行（右对齐「导出收藏」）→ TabRow 三 tab
//  （「影片 (n)/帖子 (n)/女优 (n)」，默认选中 0）→ 内容区。loading → LoadingBox；
//  rows 空 → EmptyBox「暂无收藏 — 在详情页点 ☆ 收藏」；行卡（标题 13pt Medium 2 行省略，
//  空则「(无标题)」；时间 yyyy-MM-dd HH:mm 本地时区，ts<=0 →「时间未知」）。
//  点击路由：movie → movie/{id}；sht → sht/{tid}；actor → actor/{id}。
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
        VStack(spacing: 0) {
            topRow
            tabBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
        .onAppear { Task { await vm.reload() } }   // bind 即 reload（不随 dataEpoch 自动刷新）
        .sheet(isPresented: $showExportShare) {
            // ACTION_SEND text/plain 对位（chooser 标题「导出收藏」由系统面板承载）
            ActivityShareSheet(activityItems: [exportPayload])
        }
        .accessibilityIdentifier("tab_root_favs")
    }

    // MARK: 顶部行（右对齐「导出收藏」）

    private var topRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                exportPayload = vm.exportText()
                showExportShare = true
            } label: {
                AppText(FavsCopy.exportButton, lvl: .bodyS, color: theme.accent,
                        fontWeight: .medium)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("favs_export")
        }
        .padding(.horizontal, 8)
    }

    // MARK: TabRow 三 tab（文案带数量；默认选中 0）

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(FavsCopy.tabs.enumerated()), id: \.offset) { i, t in
                tabCell(t.label, kind: t.kind, selected: tab == t.kind)
                if i < FavsCopy.tabs.count - 1 { Divider().frame(height: 20) }
            }
        }
        .frame(height: 46)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func tabCell(_ label: String, kind: String, selected: Bool) -> some View {
        Button {
            tab = kind
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                AppText(FavsCopy.tabLabel(label, vm.count(kind)), lvl: .bodyS,
                        color: selected ? theme.accent : theme.text2,
                        maxLines: 1, fontWeight: selected ? .semibold : .regular)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(selected ? theme.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("favs_tab_\(kind)")
    }

    // MARK: 内容区（loading → LoadingBox；空 → EmptyBox；行卡列表）

    @ViewBuilder
    private var content: some View {
        if vm.loading {
            LoadingBox()
        } else if rows.isEmpty {
            EmptyBox(text: FavsCopy.emptyText)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        FavRowCard(row: r) {
                            tap(r)
                        }
                    }
                }
                .padding(.vertical, 4)
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
        .padding(.vertical, 4)
        .cardChrome()
        .accessibilityIdentifier("fav_row")
    }
}
