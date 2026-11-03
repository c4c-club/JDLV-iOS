import UIKit

/**
 * 测试图片模式（对齐 Android core/img/TestImages.kt; ★ S11-P8 需求 8）——
 * 真机实测/截图/演示时把 App 里**所有图片位**替换为本地生成的彩色测试块
 * （原始图片含敏感内容）。
 *
 * 零新增依赖、零二进制资源: 首次调用时生成 6 张 400×269 纯色块 + 序号 +
 * "TEST IMG" 水印（269 ≈ 538/2 → 800:538 横版封面走 CoverHalf 时 w>=h*1.2
 * 仍成立, 裁半行为与真图一致）。同一 key 稳定映射到同一张（hashCode 均摊）
 * → 列表滚动不闪、灯箱序号稳定。
 *
 * ★ DEBUG 隔离: 整个实现包在 #if DEBUG —— Release 编译 enabled() 恒 false、
 * testImage(for:) 恒 nil（对齐 Android 仅 FLAG_DEBUGGABLE 构建在设置页暴露）。
 */
enum TestImages {
    #if DEBUG

    private static let N = 6
    private static let W = 400
    private static let H = 269            // ≈ 800:538, 保证 CoverHalf (w >= h*1.2) 会生效
    /// ARGB 0xFF4F7CF7 / 0xFFF76F4F / 0xFF4FBF7C / 0xFFB84FF7 / 0xFFF7C84F / 0xFF4FD2F7
    /// （蓝/橙红/绿/紫/黄/天蓝, 逐字）
    private static let COLORS: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (0x4F, 0x7C, 0xF7), (0xF7, 0x6F, 0x4F), (0x4F, 0xBF, 0x7C),
        (0xB8, 0x4F, 0xF7), (0xF7, 0xC8, 0x4F), (0x4F, 0xD2, 0xF7),
    ]

    private static let lock = NSLock()
    private static var blocks: [UIImage?] = Array(repeating: nil, count: N)
    private static var ready = false

    /// 读设置 testImgMode（默认 false; provider 兜底 → 异常语义等价 Android runCatching 兜 false）
    static func enabled() -> Bool {
        CdnRewrite.settings().testImgMode
    }

    /// 同一 key 稳定映射到同一张（列表滚动不闪）:
    /// i = (Java String.hashCode(key) & 0x7fffffff) % 6
    static func testImage(for url: String) -> UIImage? {
        ensure()
        let i = Int(javaHashCode(url) & 0x7fffffff) % N
        return blocks[i]
    }

    /// 关闭测试模式时调用: 清就绪标记与内存块（下次开启重新生成）
    static func clearCache() {
        lock.lock()
        ready = false
        blocks = Array(repeating: nil, count: N)
        lock.unlock()
    }

    /// 双检锁惰性生成（Android ensure(): 生成一次永久复用; iOS 直接内存持有,
    /// 不落盘 —— file:// 形态是 Coil 特有, iOS 管线直接消费 UIImage）
    private static func ensure() {
        if ready { return }
        lock.lock()
        if !ready {
            for i in 0..<N where blocks[i] == nil {
                blocks[i] = render(i)
            }
            ready = true
        }
        lock.unlock()
    }

    /// 400×269 纯色块 + 大字序号 "#i"（96f 白色, 居中, 基线 H/2）+
    /// 水印 "TEST IMG"（40f, 基线 H/2 + 64f）; Paint.ANTI_ALIAS_FLAG 对位:
    /// UIKit 绘制默认抗锯齿。
    private static func render(_ i: Int) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1                      // 精确 400×269 像素
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt)
        return renderer.image { _ in
            let c = COLORS[i]
            UIColor(red: CGFloat(c.r) / 255.0, green: CGFloat(c.g) / 255.0,
                    blue: CGFloat(c.b) / 255.0, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: W, height: H))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 96),
                .foregroundColor: UIColor.white,           // 0xFFFFFFFF
            ]
            drawCentered("#\(i)", baselineY: CGFloat(H) / 2, attrs: attrs)
            var attrs2 = attrs
            attrs2[.font] = UIFont.systemFont(ofSize: 40)
            drawCentered("TEST IMG", baselineY: CGFloat(H) / 2 + 64, attrs: attrs2)
        }
    }

    /// Android Paint.Align.CENTER + drawText(x=W/2, y=baseline) 对位:
    /// iOS draw(at:) 是左上角锚点 → x 居中、y = baseline - ascender 近似基线对齐
    private static func drawCentered(_ s: String, baselineY: CGFloat,
                                     attrs: [NSAttributedString.Key: Any]) {
        let size = (s as NSString).size(withAttributes: attrs)
        let x = (CGFloat(W) - size.width) / 2
        let font = attrs[.font] as? UIFont ?? UIFont.systemFont(ofSize: 40)
        (s as NSString).draw(at: CGPoint(x: x, y: baselineY - font.ascender), withAttributes: attrs)
    }

    /**
     * Java String.hashCode 逐字移植（Kotlin String.hashCode 与 Swift hashValue
     * 不同 —— 必须移植 Java 版才能与 Android 同 key 同图）:
     * h = s[0]*31^(n-1) + s[1]*31^(n-2) + ... + s[n-1]; char 用 UTF-16 码元;
     * int32 溢出回绕语义（&* &+）。
     */
    static func javaHashCode(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 {
            h = h &* 31 &+ Int32(u)
        }
        return h
    }

    #else

    /// Release 编译: 测试图片模式恒不可用
    static func enabled() -> Bool { false }

    /// Release 编译: 恒返回 nil
    static func testImage(for url: String) -> UIImage? { nil }

    static func clearCache() {}

    #endif
}
