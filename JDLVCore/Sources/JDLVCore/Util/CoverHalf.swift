import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 封面左/右半裁切（对齐 Android `core/img/CoverHalf.kt`，P4 2026-10-31）。
///
/// 远程封面是 **800×538 正反两半合并横图**（docs/64 §1.2）；小图模式（400:520
/// 竖卡）只显示一半 —— 默认右半（正面），可配左半。
/// mode/which: **0 = 右半（默认）/ 1 = 左半 / 2 = 整张**（整张不挂本变换 → nil）。
///
/// 本类型是纯几何计算（Foundation-only，可 Linux 单测）；位图裁切由 App 层用
/// `CGImage.cropping(to:)` 消费本结果（异常回原图，单张坏图不拖垮加载）。
public enum CoverHalf {
    /// 裁切矩形（输入图像素坐标，原点左上，与 CGImage 坐标一致）。
    ///
    /// 算法逐字（Android transform）:
    /// ```
    /// if (w >= h * 12 / 10 && w >= 2) {          // 宽 >= 高×1.2 才是合并横图（整数运算）
    ///     val x = if (which == 1) 0 else w / 2
    ///     Bitmap.createBitmap(input, x, 0, w - x, h)
    /// } else input
    /// ```
    /// 即 x = mode==1 ? 0 : w/2、宽 = w - x（mode=1 → (0..w)，mode=0 → (w/2..w)）。
    /// 不满足条件 / mode==2 / 宽高为 0 防御 → nil（调用方回原图）。
    public static func cropRect(cw: Int, ch: Int, mode: Int) -> CGRect? {
        if mode == 2 { return nil }                // 整图: 不挂本变换
        let w = cw, h = ch
        if w <= 0 || h <= 0 { return nil }         // 宽高为 0 防御 (Android createBitmap 抛异常 → catch 回原图)
        if w >= h * 12 / 10 && w >= 2 {
            let x = (mode == 1) ? 0 : w / 2
            let width = w - x
            if width <= 0 { return nil }
            return CGRect(x: x, y: 0, width: width, height: h)
        }
        return nil
    }

    /// Coil Transformation.cacheKey 对位: "coverHalf_$which"
    public static func cacheKey(_ mode: Int) -> String { "coverHalf_\(mode)" }
}
