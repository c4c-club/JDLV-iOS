import SwiftUI

//
//  Lightbox.swift —— 全屏灯箱（08 B.3 / 10 §1.5：帖子详情、影片详情、资讯详情共用）。
//
//  - 全屏黑底；HorizontalPager 对位 TabView(.page) 横滑翻页（相邻页预加载天然满足）。
//  - 手势（未放大 scale ≤ 1.5）：点左 1/3（x < 30% 宽）→ 上一页；点右 1/3（x > 70% 宽）
//    → 下一页；中间无动作；单指横滑交给翻页。
//  - 放大状态：点按不翻页；单指拖动平移。
//  - 双击：scale > 1.5 → 复位 1.0，否则放大 2.5（offset 归零）。
//  - 双指捏合：scale clamp 1..6，跟手平移。
//  - 左下角页码「{当前页+1} / {总页数}」（白 75% 透明，12pt）；右上角关闭按钮
//    「✕ 关闭」（白 12pt）；urls 为空居中「无图」（#9aa0ad）。
//

/// 灯箱阈值（DesignTokenTests 断言用）。
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
        ZStack {
            Color.black.ignoresSafeArea()
            if urls.isEmpty {
                emptyState
            } else {
                pager
                chrome
            }
        }
    }

    // MARK: 空态（「无图」）

    private var emptyState: some View {
        AppText("无图", lvl: .meta, color: .lightboxEmptyText)
    }

    // MARK: 翻页

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(urls.indices, id: \.self) { i in
                LightboxPage(url: urls[i],
                             onPrev: { go(-1) },
                             onNext: { go(1) })
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < urls.count else { return }
        withAnimation { index = next }
    }

    // MARK: 页码 + 关闭

    private var chrome: some View {
        VStack(spacing: 0) {
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
            .padding(.top, 4)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                AppText("\(index + 1) / \(urls.count)", lvl: .meta,
                        color: .white.opacity(LightboxMetrics.pageIndicatorOpacity))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

/// 「无图」文案色 #9aa0ad（自建 RGB，不走 Theme 的 Color(hex:) —— 该入口对 6 位 hex
/// 把 alpha 字节解析为 0（透明），Reader/Lightbox 一律用显式 RGB 构造，见移植报告）。
private extension Color {
    static let lightboxEmptyText = Color(red: 0x9A / 255.0, green: 0xA0 / 255.0, blue: 0xAD / 255.0)
}

// MARK: - 单页（缩放 + 平移 + 点区翻页）

private struct LightboxPage: View {
    let url: String
    var onPrev: () -> Void
    var onNext: () -> Void

    @State private var scale: CGFloat = LightboxMetrics.minZoom
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pan: CGSize = .zero

    private var isZoomed: Bool { scale > LightboxMetrics.zoomedThreshold }

    var body: some View {
        GeometryReader { geo in
            PosterImage(url: url, radius: 0)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale * gestureScale)
                .offset(x: offset.width + pan.width, y: offset.height + pan.height)
                .gesture(magnify)
                .simultaneousGesture(drag)
                .gesture(SpatialTapGesture().onEnded { value in
                    guard !isZoomed else { return }   // 放大态点按不翻页
                    let w = max(geo.size.width, 1)
                    let x = value.location.x / w
                    if x < LightboxMetrics.prevTapZone {
                        onPrev()
                    } else if x > LightboxMetrics.nextTapZone {
                        onNext()
                    }
                })
                .onTapGesture(count: 2) {
                    withAnimation {
                        if isZoomed {
                            scale = LightboxMetrics.minZoom
                            offset = .zero
                        } else {
                            scale = LightboxMetrics.doubleTapZoom
                            offset = .zero
                        }
                    }
                }
        }
    }

    /// 双指捏合 1–6（onChanged 跟手、onEnded 落定 clamp）
    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { gestureScale = $0 }
            .onEnded { v in
                let target = min(max(scale * v, LightboxMetrics.minZoom), LightboxMetrics.maxZoom)
                withAnimation {
                    scale = target
                    if target <= LightboxMetrics.minZoom { offset = .zero }
                }
                gestureScale = 1
            }
    }

    /// 放大态单指拖动平移（未放大交给 Pager 翻页）
    private var drag: some Gesture {
        DragGesture()
            .updating($pan) { v, state, _ in
                guard isZoomed else { return }
                state = v.translation
            }
            .onEnded { v in
                guard isZoomed else { return }
                offset = CGSize(width: offset.width + v.translation.width,
                                height: offset.height + v.translation.height)
            }
    }
}
