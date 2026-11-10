import SwiftUI
import JDLVCore

//
//  AspectImage.swift —— 设计系统 v2 统一图片组件（13 §3.3：先定框，再填充）。
//
//  铁律（13 §3.1 原则 7）：布局尺寸由 Color.clear 决定，图片只做 overlay；
//  禁止 scaledToFill 直接放在参与布局的 ZStack/VStack 里（问题 5/6/8 根因）。
//
//  - ratio 非空：`Color.clear.aspectRatio(ratio, .fit).overlay { img }.clipped()`
//  - ratio 空：填满调用方给定 frame（overlay 撑满 overlay 层，不反压布局）。
//  - fill=true  scaledToFill（封面裁切语义）；fill=false scaledToFit（灯箱/正文图完整语义）。
//  - 三态占位与 PosterImage 同口径：NoCover 虚线框 / Loading 16pt 转圈 / Failed 可点重试。
//  - DEBUG + demo/测试图片模式 → TestImages 纯色块（同 key 稳定同图，不发请求）。
//  - 请求键 reqKey = "{url}|{halfMode|-1}|{retryKey}"（B12 逐字口径，与 PosterImage 一致）。
//

struct AspectImage: View {
    enum Phase: Equatable {
        case noCover, loading, ok, failed
    }

    let url: String
    /// nil = 填满父框；给值 = 固定宽高比（如 3/4.0、16/9.0、1）
    var ratio: CGFloat? = nil
    /// true = scaledToFill 裁切（卡片封面）；false = scaledToFit 完整显示（灯箱/正文）
    var fill: Bool = true
    /// 小图模式取半图（按设置 coverHalf；整张设置不裁）
    var half: Bool = false
    /// 灯箱等全屏位传 0（照片不裁圆角）
    var radius: CGFloat = ComponentMetrics.imageCorner
    var onRetry: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var phase: Phase = .loading
    @State private var image: UIImage? = nil
    @State private var retryKey = 0
    // R4 P4：实际 frame（GeometryReader 只作背景测量，不参与布局）→ 解码像素上限
    @State private var frameSize: CGSize = .zero

    private var halfMode: Int { half ? ImgBreaker.halfMode() : 2 }
    private var reqKey: String { "\(url)|\(half ? halfMode : -1)|\(retryKey)" }

    /// 解码上限 = 实际 frame 最长边 × 屏幕倍率（§6.3）；未测量到（0）= 不限
    private var maxPixel: Int {
        let s = max(frameSize.width, frameSize.height)
        guard s > 0 else { return 0 }
        return Int(s * UIScreen.main.scale)
    }

    var body: some View {
        frameLayer
            .overlay(contentLayer)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frameSize = geo.size }
                        .onChange(of: geo.size) { frameSize = $0 }
                }
            )
            .task(id: reqKey) { await load() }
            // R4 P4：滑出屏幕即取消在飞加载（Coil onDetached 语义；变体缓存键不受影响）
            .onDisappear { ImagePipeline.shared.cancel(for: url) }
    }

    /// 布局层：ratio 非空 → Color.clear.aspectRatio 定框（唯一尺寸来源）；
    /// ratio 空 → Color.clear 撑满父给的 frame。
    private var frameLayer: some View {
        Group {
            if let r = ratio {
                Color.clear.aspectRatio(r, contentMode: .fit)
            } else {
                Color.clear
            }
        }
    }

    /// 内容层：占位或图片（图片只做 overlay + 裁切，不参与布局）
    @ViewBuilder
    private var contentLayer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(theme.bg3)
            switch phase {
            case .noCover:
                noCoverPlaceholder
            case .loading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 16, height: 16)
            case .ok:
                if let img = image {
                    if fill {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    }
                }
            case .failed:
                failedPlaceholder
            }
        }
    }

    // MARK: 三态占位（与 PosterImage 同口径）

    private var noCoverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [9, 7]))
                .foregroundColor(theme.line)
                .padding(8)
            AppText("🖼", lvl: .titleM, color: theme.text2)
        }
    }

    private var failedPlaceholder: some View {
        ZStack {
            AppText(AppCopy.posterFailedRetry, lvl: .meta, color: theme.text2, textAlign: .center)
                .padding(.horizontal, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            ImgBreaker.shared.resetCooling()
            retryKey += 1
            onRetry?()
        }
    }

    // MARK: 加载（与 PosterImage 同链路）

    private func load() async {
        if url.isEmpty {
            phase = .noCover
            image = nil
            return
        }
        #if DEBUG
        if DemoDataSource.enabled() || TestImages.enabled() {
            if let img = TestImages.testImage(for: reqKey) {
                image = img
                phase = .ok
                return
            }
        }
        #endif
        phase = .loading
        let kind = CdnRewrite.kindOf(url)
        let img = await ImagePipeline.shared.image(url: url, kind: kind, half: halfMode,
                                                   maxPixel: maxPixel)
        if Task.isCancelled { return }
        if let img {
            image = img
            phase = .ok
        } else {
            image = nil
            phase = .failed
        }
    }
}
