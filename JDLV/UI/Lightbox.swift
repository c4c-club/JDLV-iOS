import SwiftUI

//
//  Lightbox.swift —— 全屏灯箱（13 §2.8/§4.16 设计系统 v2 重写：fit 不裁切）。
//
//  v2（问题 8 根因修复）：
//  - 每页 ZoomableImage（UIScrollView scaleAspectFit —— 图片完整显示，四边黑边；
//    旧 PosterImage fill 语义裁切退役）。
//  - 手势：双击 2.5×/复位（点击点为中心）；放大后单指平移 clamp；未放大单击
//    左/右 1/3 翻页；横滑翻页交给 TabView(.page)。
//  - chrome 用 safeAreaInset（页码/关闭避开刘海与 Home Indicator）；背景纯黑。
//  - 左下角页码「{当前页+1} / {总页数}」（白 75%，12pt）；右上角「✕ 关闭」；
//    urls 为空居中「无图」。
//

/// 灯箱阈值（DesignTokenTests 断言用；与 ZoomableImage 共用）。
enum LightboxMetrics {
    static let doubleTapZoom: CGFloat = 2.5
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 6
    /// scale > 1.5 视为放大态（点按翻页让位给拖动）
    static let zoomedThreshold: CGFloat = 1.5
    /// 点左 30% → 上一页
    static let prevTapZone: CGFloat = 0.3
    /// 点右 70% 以右 → 下一页
    static let nextTapZone: CGFloat = 0.7
    static let pageIndicatorOpacity: Double = 0.75
    /// 「无图」文案色（#9aa0ad）
    static let emptyColorHex: UInt32 = 0x9AA0AD
}

struct Lightbox: View {
    let urls: [String]
    var initialIndex: Int = 0
    var onClose: () -> Void

    @State private var index: Int

    init(urls: [String], initialIndex: Int = 0, onClose: @escaping () -> Void) {
        self.urls = urls
        self.initialIndex = initialIndex
        self.onClose = onClose
        _index = State(initialValue: max(0, min(initialIndex, max(0, urls.count - 1))))
    }

    var body: some View {
        Group {
            if urls.isEmpty {
                emptyState
            } else {
                pager
            }
        }
        .safeAreaInset(edge: .top) { topChrome }
        .safeAreaInset(edge: .bottom) { bottomChrome }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: 空态（「无图」）

    private var emptyState: some View {
        AppText("无图", lvl: .meta, color: .lightboxEmptyText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
    }

    // MARK: 翻页（ZoomableImage 每页；换页时新实例 → 缩放自动复位）

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(urls.indices, id: \.self) { i in
                ZoomableImage(url: urls[i],
                              onPrev: { go(-1) },
                              onNext: { go(1) })
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .accessibilityIdentifier("lightbox_pager")
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < urls.count else { return }
        withAnimation { index = next }
    }

    // MARK: chrome（safeAreaInset：不压刘海/Home Indicator）

    private var topChrome: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                onClose()
            } label: {
                AppText("✕ 关闭", lvl: .meta, color: .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lightbox_close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.001))
    }

    private var bottomChrome: some View {
        HStack(spacing: 0) {
            if !urls.isEmpty {
                AppText("\(index + 1) / \(urls.count)", lvl: .meta,
                        color: .white.opacity(LightboxMetrics.pageIndicatorOpacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.001))
    }
}

/// 「无图」文案色 #9aa0ad（自建 RGB，不走 Theme 的 Color(hex:) —— 该入口对 6 位 hex
/// 把 alpha 字节解析为 0（透明），Reader/Lightbox 一律用显式 RGB 构造，见移植报告）。
private extension Color {
    static let lightboxEmptyText = Color(red: 0x9A / 255.0, green: 0xA0 / 255.0, blue: 0xAD / 255.0)
}
