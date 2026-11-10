import UIKit
import ImageIO

/// R4 P4：图片单次降采样解码（§6.3 —— `CGImageSourceCreateThumbnailAtIndex`）。
///
/// 旧路径 `UIImage(data:)` 会先按原始尺寸解码（一张 800×1200 封面 ≈ 3.8MB 位图），
/// 再被 `coverHalf` 裁半；首页 3×24 张卡同帧解码 → 内存尖峰 jetsam。
/// 新路径在解码阶段就把最长边压到 maxPixel，内存峰值 ≈ 目标像素面积 ×4 字节。
///
/// - 线程安全：ImageIO 无共享可变状态，可在任意队列调用（ImagePipeline 用 Task.detached 调入）。
/// - maxPixel ≤ 0 = 不限（全尺寸单次解码；灯箱等全屏场景用）。
enum ImageDecoder {

    /// data → 降采样位图（最长边 ≤ maxPixel；kCGImageSourceCreateThumbnailWithTransform
    /// 按源图 EXIF 方向摆正）。解码失败/空数据返回 nil（调用方走 recordFailure 路径）。
    static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard !data.isEmpty else { return nil }
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts),
              CGImageSourceGetCount(src) > 0 else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if maxPixel > 0 {
            opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
