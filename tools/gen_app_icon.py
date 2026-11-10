#!/usr/bin/env python3
"""R4 P7：生成 1024×1024 AppIcon（任务 09 §10.2）。

规格：1024×1024、RGB（无 alpha）、sRGB；深色底 #0F1218 + 紫渐变 #7C5CFF→#3D8BFF
对角带 + 白色几何播放三角；不预切圆角（系统统一裁切）。

用法：python tools/gen_app_icon.py [输出路径]
  默认输出 JDLV/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

W = H = 1024
DARK = (0x0F, 0x12, 0x18)
GRAD_TOP = (0x7C, 0x5C, 0xFF)   # 紫
GRAD_BOTTOM = (0x3D, 0x8B, 0xFF)  # 蓝


def build() -> Image.Image:
    base = Image.new("RGB", (W, H), DARK)

    # 对角渐变层（linear_gradient: 0 顶部 → 255 底部；rotated 45° 变对角）
    g = Image.linear_gradient("L").resize((W, H)).rotate(-45, expand=False)
    grad = Image.merge("RGB", [
        g.point(lambda v, i=i: int(GRAD_TOP[i] + (GRAD_BOTTOM[i] - GRAD_TOP[i]) * v / 255))
        for i in range(3)
    ])

    # 对角带蒙版（左下 → 右上，半透明叠加在深色底上）
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    d.polygon([(0, H), (W, 0), (W, int(H * 0.66)), (int(W * 0.34), H)], fill=170)

    out = Image.composite(grad, base, mask)

    # 白色几何播放三角（居中，几何硬边——不描边不圆角）
    d2 = ImageDraw.Draw(out)
    d2.polygon([(int(W * 0.40), int(H * 0.30)),
                (int(W * 0.40), int(H * 0.70)),
                (int(W * 0.74), int(H * 0.50))], fill=(255, 255, 255))

    return out


def main() -> int:
    out = (sys.argv[1] if len(sys.argv) > 1
           else "JDLV/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    p = Path(out)
    p.parent.mkdir(parents=True, exist_ok=True)
    im = build()
    im.save(p, format="PNG")
    # 自检：1024×1024 / RGB / 无 alpha（§10.2）
    im2 = Image.open(p)
    assert im2.size == (1024, 1024), im2.size
    assert im2.mode == "RGB", im2.mode
    print("OK", p, im2.size, im2.mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
