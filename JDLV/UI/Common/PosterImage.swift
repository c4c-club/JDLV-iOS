import SwiftUI
import UIKit
import JDLVCore

//
//  PosterImage.swift —— 统一封面组件（07 B12 / 10 §0.5，S10-P0 重写语义）。
//
//  三态占位（静态，不跳变）：
//  - NoCover（url 空）：内缩 8pt 虚线圆角框（圆角 10、线宽 1、dash [9,7]、outlineVariant）
//    居中 🖼 TitleM；无文案无重试。
//  - Loading：16pt 转圈（strokeWidth 2 对位）。
//  - Failed："加载失败 · 点击重试" Meta；整个占位可点（无涟漪）→ resetCooling +
//    retryKey++（换缓存键绕过失败缓存）+ onRetry 回调。
//
//  - 容器：圆角 10 + surfaceVariant 底（theme.bg3）。
//  - half=true 时按设置 coverHalf（0 右半 / 1 左半 / 2 整张）裁半，交给图片管线
//    （ImagePipeline.applyHalf ↔ Android CoverHalf）。
//  - 请求键 reqKey = "{url}|{halfMode|-1}|{retryKey}"（B12 逐字口径）。
//  - 成功/失败上报（Img.onOk/onFail ↔ 熔断冷却）在 ImagePipeline 内部完成，本组件不重复上报。
//  - DEBUG + demo 模式（-JDLV_DEMO 1）或设置 testImgMode 开启时直接显示 TestImages
//    纯色块（★ S11-P8：所有图片位统一替换，不发网络请求）。
//

struct PosterImage: View {
    enum Phase: Equatable {
        case noCover, loading, ok, failed
    }

    let url: String
    /// true = 小图模式取半图（按设置 coverHalf；整张设置不裁）
    var half: Bool = false
    /// nil = 填满调用方给的 frame；给值 = 固定宽高比（如 400/520、800/520、1.6、4/5.0）
    var aspect: CGFloat? = nil
    /// 灯箱等全屏位传 0（照片不裁圆角）
    var radius: CGFloat = ComponentMetrics.imageCorner
    var onRetry: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var phase: Phase = .loading
    @State private var image: UIImage? = nil
    @State private var retryKey = 0

    /// half 且设置非整张时才挂 CoverHalf（B12：halfMode==2 整张不裁）
    private var halfMode: Int { half ? ImgBreaker.halfMode() : 2 }
    private var reqKey: String { "\(url)|\(half ? halfMode : -1)|\(retryKey)" }

    var body: some View {
        Group {
            if let a = aspect {
                core.aspectRatio(a, contentMode: .fit)
            } else {
                core
            }
        }
        .task(id: reqKey) { await load() }
    }

    private var core: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(theme.bg3)
            switch phase {
            case .noCover: noCoverPlaceholder
            case .loading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 16, height: 16)
            case .ok:
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: radius))
                }
            case .failed: failedPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    // MARK: 三态占位

    /// 无封面：内缩 8pt 虚线圆角框 + 🖼（无文案无重试）
    private var noCoverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [9, 7]))
                .foregroundColor(theme.line)
                .padding(8)
            AppText("🖼", lvl: .titleM, color: theme.text2)
        }
    }

    /// 加载失败：整块可点（clickableNoRipple → onTapGesture）
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

    // MARK: 加载

    private func load() async {
        if url.isEmpty {
            phase = .noCover
            image = nil
            return
        }
        // DEBUG：demo 模式 / 测试图片模式 → TestImages 纯色块（同 key 稳定同图）
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
        let img = await ImagePipeline.shared.image(url: url, kind: kind, half: halfMode)
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
