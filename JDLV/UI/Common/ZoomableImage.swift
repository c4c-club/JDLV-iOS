import SwiftUI
import JDLVCore

//
//  ZoomableImage.swift —— 灯箱单页缩放容器（R3 问题 8：13 §3.3）。
//
//  UIViewRepresentable 包 UIScrollView + UIImageView：
//  - contentMode = .scaleAspectFit（fit 不裁切；图片完整显示，四边留黑边）
//  - minimumZoomScale = 1 / maximumZoomScale = 6 / bouncesZoom = true
//  - 双击：以点击点为中心 2.5×，再双击复位（zoomScale 归 1）
//  - 单指拖动：zoomScale > 1 时 UIScrollView 原生平移 + clamp 到内容边界
//  - 单击：zoomScale == 1 时左 1/3 上一页、右 1/3 下一页（回调宿主 TabView）
//  - 加载中 spinner；失败「加载失败 · 点击重试」；demo/测试图模式走 TestImages
//

struct ZoomableImage: View {
    let url: String
    var onPrev: () -> Void = {}
    var onNext: () -> Void = {}

    @State private var image: UIImage? = nil
    @State private var failed = false
    @State private var retryKey = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = image {
                ZoomableScrollView(image: img, onPrev: onPrev, onNext: onNext)
            } else if failed {
                Button {
                    failed = false
                    retryKey += 1
                } label: {
                    Text("加载失败 · 点击重试")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(10)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .task(id: "\(url)|\(retryKey)") { await load() }
    }

    private func load() async {
        guard !url.isEmpty else { return }
        #if DEBUG
        if DemoDataSource.enabled() || TestImages.enabled(),
           let img = TestImages.testImage(for: url) {
            image = img
            failed = false
            return
        }
        #endif
        failed = false
        let kind = CdnRewrite.kindOf(url)
        let img = await ImagePipeline.shared.image(url: url, kind: kind, half: 2)
        if Task.isCancelled { return }
        image = img
        failed = (img == nil)
    }
}

// MARK: - UIScrollView 缩放/平移/单击翻页

private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    var onPrev: () -> Void
    var onNext: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = LightboxMetrics.minZoom
        sv.maximumZoomScale = LightboxMetrics.maxZoom
        sv.bouncesZoom = true
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.backgroundColor = .black

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = sv.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sv.addSubview(iv)
        context.coordinator.imageView = iv

        // 双击：以点击点为中心 2.5× / 复位
        let dbl = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.doubleTapped(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)
        // 单击：zoom==1 时左/右 1/3 翻页
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.singleTapped(_:)))
        single.numberOfTapsRequired = 1
        single.require(toFail: dbl)
        sv.addGestureRecognizer(single)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            context.coordinator.resetZoom(sv)
        }
        // 换页（新宿主实例）复位：zoomScale 由新实例初始 1 保证；offset 归零兜底
        if sv.zoomScale != LightboxMetrics.minZoom && sv.bounds.size == .zero {
            sv.zoomScale = LightboxMetrics.minZoom
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        weak var imageView: UIImageView?

        init(_ parent: ZoomableScrollView) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // 内容居中（缩放后宽/高小于视口时）
            let sv = scrollView
            guard let iv = imageView else { return }
            let w = max(iv.frame.width, sv.bounds.width)
            let h = max(iv.frame.height, sv.bounds.height)
            sv.contentSize = CGSize(width: w, height: h)
            let dx = max(0, (sv.bounds.width - w) / 2)
            let dy = max(0, (sv.bounds.height - h) / 2)
            iv.center = CGPoint(x: w / 2 + dx, y: h / 2 + dy)
        }

        func resetZoom(_ sv: UIScrollView) {
            sv.setZoomScale(LightboxMetrics.minZoom, animated: false)
            sv.contentOffset = .zero
        }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            let target: CGFloat = sv.zoomScale > 1 ? LightboxMetrics.minZoom
                                                   : LightboxMetrics.doubleTapZoom
            if target == LightboxMetrics.minZoom {
                sv.setZoomScale(target, animated: true)
                sv.contentOffset = .zero
            } else {
                let point = g.location(in: imageView)
                let size = sv.bounds.size
                let rect = CGRect(x: point.x * target - size.width / 2,
                                  y: point.y * target - size.height / 2,
                                  width: size.width, height: size.height)
                sv.zoom(to: rect, animated: true)
            }
        }

        @objc func singleTapped(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView,
                  sv.zoomScale <= LightboxMetrics.zoomedThreshold else { return }
            let w = max(sv.bounds.width, 1)
            let x = g.location(in: sv).x / w
            if x < LightboxMetrics.prevTapZone {
                parent.onPrev()
            } else if x > LightboxMetrics.nextTapZone {
                parent.onNext()
            }
        }
    }
}
