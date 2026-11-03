import SwiftUI

//
//  LoadMoreFooter.swift —— 翻页 footer（07 B19、08 A.5、10 §0.3）。
//
//  - 首次出现自动补一页（autoDone 一次性；loaded 回落到 0 时复位，NA-27），
//    之后需手点「加载更多」。
//  - loadingMore → 18pt 转圈（strokeWidth 2 对位）+ 8pt + 计数行（Meta）。
//  - 计数行：total>0 且 approx → 「已加载 {loaded} · 约 {total} 条」；total>0 →
//    「已加载 {loaded} / {total}」；total<=0 → 「已加载 {loaded} 条」；
//    totalLine 回调非空时由调用方自定义（如 98t "2 万帖窗口内"）。
//  - note 非空 → Meta tertiary 居中（padding h24，派生范围标注）。
//  - hasMore && !loadingMore && loaded>0 → 「加载更多」（13pt Medium，minHeight 48）。
//  - !hasMore && loaded>0 → 「没有更多了」Meta（onSurfaceVariant）。
//

/// ListScaffold 集成用配置（页面把 VM 状态搬进来；nil = 页面无分页/自带 footer）。
struct LoadMoreConfig {
    var loaded: Int
    var total: Int64 = -1
    var loadingMore: Bool = false
    var approx: Bool = false
    var note: String = ""
    var hasMore: Bool = true
    /// 自定义计数行（98t totalLine 对位）；nil → 默认三段式
    var totalLine: ((Int) -> String)? = nil
    var onLoadNext: () -> Void = {}

    init(loaded: Int, total: Int64 = -1, loadingMore: Bool = false, approx: Bool = false,
         note: String = "", hasMore: Bool = true,
         totalLine: ((Int) -> String)? = nil, onLoadNext: @escaping () -> Void = {}) {
        self.loaded = loaded
        self.total = total
        self.loadingMore = loadingMore
        self.approx = approx
        self.note = note
        self.hasMore = hasMore
        self.totalLine = totalLine
        self.onLoadNext = onLoadNext
    }
}

struct LoadMoreFooter: View {
    let config: LoadMoreConfig

    @Environment(\.appTheme) private var theme
    @State private var autoDone = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if config.loadingMore {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(width: 18, height: 18)
                }
                AppText(countLine, lvl: .meta)
            }
            if !config.note.isEmpty {
                AppText(config.note, lvl: .meta, color: theme.accent2, textAlign: .center)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
            if config.hasMore && !config.loadingMore && config.loaded > 0 {
                Button {
                    config.onLoadNext()
                } label: {
                    AppText(AppCopy.loadMore, lvl: .meta, color: theme.accent,
                            fontWeight: .medium)
                        .padding(.horizontal, 24)
                        .frame(minHeight: ComponentMetrics.buttonMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !config.hasMore && config.loaded > 0 {
                AppText(AppCopy.noMore, lvl: .meta)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .onAppear { autoLoadOnce() }
        .onChange(of: config.loaded) { newValue in
            if newValue <= 0 { autoDone = false }   // NA-27：回落复位
        }
    }

    private func autoLoadOnce() {
        guard !autoDone, config.hasMore, !config.loadingMore, config.loaded > 0 else { return }
        autoDone = true
        config.onLoadNext()
    }

    /// 计数行（totalLine 回调优先）
    private var countLine: String {
        if let f = config.totalLine { return f(config.loaded) }
        return AppCopy.loadedLine(loaded: config.loaded, total: config.total, approx: config.approx)
    }
}
