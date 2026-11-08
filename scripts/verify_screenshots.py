# -*- coding: utf-8 -*-
"""P13/R3 截图校验 v2（13 §6.3：像素 + 文件名 + 唯一性 + manifest）。

- 单页：≥1 种测试色像素 ≥5000（纯色块特征）；00- 前缀（设置/开关页）豁免单页要求；
- 整套：≥3 种测试色各 ≥5000 像素；
- v2 新增：
  * 文件名必须匹配 ^\\d{2}-[a-z0-9-]+\\.png$；
  * 数量 ≥17（R3 17 张清单）；
  * SHA256 唯一数 == 文件数（不允许重复截图 —— R2 缺陷 01=02/06=07/08=09）；
  * --manifest <json>：校验 pageName 与文件名一致、无缺失/重复（页面身份）。
用法:
  python -I scripts/verify_screenshots.py <png...>
  python -I scripts/verify_screenshots.py <png...> --manifest screenshots-manifest.json
退出码 0 = 全部通过；1 = 有不达标项。
"""
import sys
import os
import re
import json
import struct
import zlib
import hashlib

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

MIN_SHOTS = 17
NAME_RE = re.compile(r"^\d{2}-[a-z0-9-]+\.png$")


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
    out = bytearray(stride * h)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
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
TOL = 6
MIN_PIXELS = 5000
MIN_COLORS_SET = 3
# 无图位页面（无任何图片槽 → 不可能有测试色块）：00 开关页、04 筛选 Form、
# 14 设置卡、15 关于 Form（13 收藏 demo 有封面、16 灯箱有测试图不豁免）
IMAGELESS_PREFIXES = ("00-", "00_", "04-", "04_", "14-", "14_", "15-", "15_")


def verify(path):
    w, h, px = read_png_rgba(path)
    counts = [0] * len(TEST_COLORS)
    for (r, g, b) in px:
        for i, (tr, tg, tb) in enumerate(TEST_COLORS):
            if abs(r - tr) <= TOL and abs(g - tg) <= TOL and abs(b - tb) <= TOL:
                counts[i] += 1
                break
    found = sum(1 for c in counts if c * 4 >= MIN_PIXELS)
    base = os.path.basename(path)
    imageless = base.startswith(IMAGELESS_PREFIXES)
    ok = imageless or found >= 1
    return ok, w, h, [c * 4 for c in counts]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def check_v2(args, manifest_path=None, min_shots=MIN_SHOTS):
    all_ok = True

    # 文件名规范
    names = [os.path.basename(a) for a in args]
    bad_names = [n for n in names if not NAME_RE.match(n)]
    if bad_names:
        print("FAIL filename pattern: %s" % bad_names)
        all_ok = False

    # 数量（--min 参数化：blocker B1 时 CI 传 16）
    if len(args) < min_shots:
        print("FAIL count: %d < %d" % (len(args), min_shots))
        all_ok = False

    # 唯一性（SHA256）
    hashes = [sha256(a) for a in args]
    uniq = set(hashes)
    print("UNIQUENESS: %d files, %d unique sha256" % (len(hashes), len(uniq)))
    if len(uniq) != len(hashes):
        seen = {}
        for n, h in zip(names, hashes):
            seen.setdefault(h, []).append(n)
        dupes = [v for v in seen.values() if len(v) > 1]
        print("FAIL duplicate screenshots: %s" % dupes)
        all_ok = False

    # manifest（页面身份）
    if manifest_path:
        with open(manifest_path, "r", encoding="utf-8") as f:
            m = json.load(f)
        pages = m.get("pages", [])
        mnames = [p.get("pageName", "") for p in pages]
        missing = sorted(set(names) - set(mnames))
        extra = sorted(set(mnames) - set(names))
        if missing:
            print("FAIL manifest missing pageName for: %s" % missing)
            all_ok = False
        if extra:
            print("FAIL manifest extra pageName: %s" % extra)
            all_ok = False
        dup_m = sorted({n for n in mnames if mnames.count(n) > 1})
        if dup_m:
            print("FAIL manifest duplicate pageName: %s" % dup_m)
            all_ok = False
        print("MANIFEST: %d pages, missing=%s extra=%s" % (len(pages), missing, extra))

    return all_ok


def main():
    argv = sys.argv[1:]
    manifest_path = None
    if "--manifest" in argv:
        i = argv.index("--manifest")
        manifest_path = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    min_shots = MIN_SHOTS
    if "--min" in argv:
        i = argv.index("--min")
        min_shots = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    args = [a for a in argv if a.lower().endswith(".png")]
    if not args:
        print("usage: verify_screenshots.py <png...> [--manifest manifest.json]")
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
    all_ok = check_v2(args, manifest_path, min_shots) and all_ok
    print("RESULT:", "PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
