# -*- coding: utf-8 -*-
"""P13 截图像素校验：纯色测试块特征（C8 修正版口径）。

- 单页：≥1 种测试色像素 ≥5000（纯色块特征；不用"唯一色数"，避免文字抗锯齿误伤）；
  以 00_ 开头的无图页面（设置页）豁免单页要求；
- 整套截图：≥3 种测试色各 ≥5000 像素分布（证明测试图片模式全局生效）。
测试色（#4F7CF7/#F76F4F/#4FBF7C/#B84FF7/#F7C84F/#4FD2F7）。
用法: python -I scripts/verify_screenshots.py <shot1.png> [shot2.png ...]
退出码 0 = 全部通过；1 = 有不达标截图（打印 FAIL 行）。
"""
import sys
import os
import struct
import zlib

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def read_png_rgba(path):
    """最小 PNG 解码（真彩 RGBA/RGB，无隔行），返回 (w, h, [r,g,b,...])。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a png")
    pos = 8
    w = h = 0
    bitdepth = colortype = None
    idat = b""
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bitdepth, colortype = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[colortype]
    if bitdepth != 8:
        raise ValueError("unsupported bitdepth %d" % bitdepth)
    stride = w * channels
    # 反滤波
    out = bytearray(stride * h)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ft == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    # 转 RGB 采样（隔 2 像素取样加速）
    px = []
    for y in range(0, h, 2):
        row = out[y * stride:(y + 1) * stride]
        for x in range(0, w, 2):
            o = x * channels
            px.append((row[o], row[o + 1], row[o + 2]))
    return w, h, px


TEST_COLORS = [
    (0x4F, 0x7C, 0xF7), (0xF7, 0x6F, 0x4F), (0x4F, 0xBF, 0x7C),
    (0xB8, 0x4F, 0xF7), (0xF7, 0xC8, 0x4F), (0x4F, 0xD2, 0xF7),
]
TOL = 6          # 通道容差
MIN_PIXELS = 5000
MIN_COLORS_SET = 3   # 整套截图：≥3 种测试色各 ≥5000（证明测试图片模式全局生效）

# 无图片内容的页面（设置页）：单页不要求测试色块
# 规范 ASCII 截图名以 "00-" 开头（00-test-image-mode-on.png）；兼容 "00_" 变体。
IMAGELESS_PREFIXES = ("00-", "00_")


def verify(path):
    w, h, px = read_png_rgba(path)
    counts = [0] * len(TEST_COLORS)
    for (r, g, b) in px:
        for i, (tr, tg, tb) in enumerate(TEST_COLORS):
            if abs(r - tr) <= TOL and abs(g - tg) <= TOL and abs(b - tb) <= TOL:
                counts[i] += 1
                break
    found = sum(1 for c in counts if c * 4 >= MIN_PIXELS)   # 采样×4 还原
    base = os.path.basename(path)
    imageless = base.startswith(IMAGELESS_PREFIXES)
    ok = imageless or found >= 1   # 单页：≥1 种测试色 ≥5000（或为无图设置页）
    return ok, w, h, [c * 4 for c in counts]


def main():
    args = [a for a in sys.argv[1:] if a.lower().endswith(".png")]
    if not args:
        print("usage: verify_screenshots.py <png...>")
        return 1
    all_ok = True
    set_colors = [0] * len(TEST_COLORS)
    for a in args:
        try:
            ok, w, h, counts = verify(a)
        except Exception as e:  # noqa
            print("FAIL %s (%s)" % (a, e))
            all_ok = False
            continue
        for i, c in enumerate(counts):
            set_colors[i] += c
        status = "OK  " if ok else "FAIL"
        print("%s %s (%dx%d) test-color pixels=%s" % (status, os.path.basename(a), w, h, counts))
        if not ok:
            all_ok = False
    set_found = sum(1 for c in set_colors if c >= MIN_PIXELS)
    set_ok = set_found >= MIN_COLORS_SET
    print("SET: %d/%d test colors >= %d px" % (set_found, len(TEST_COLORS), MIN_PIXELS))
    if not set_ok:
        all_ok = False
    print("RESULT:", "PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
