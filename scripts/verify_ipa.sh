#!/usr/bin/env bash
# R4 Phase 2：发布 IPA 安全门禁（只读；任务 03 §5.1）。
# 用法：bash scripts/verify_ipa.sh <path/to/JDLV-unsigned.ipa>
# 检查：文件白名单 / 坏扩展名（txt/md/env/mysql*/db/sqlite*/sql）/ JDLV 二进制
# ASCII+UTF-16 口令模式扫描 / 已知密钥值比对（JDLV_KNOWN_SECRETS_FILE，未配置跳过）。
# 最后一行 `IPA VERIFY: PASS` 才 exit 0；违规输出 `IPA VERIFY: FAIL`（只输出路径/偏移/长度，不输出值）。
# 注意：NSAllowsArbitraryLoads 只 WARN 不拦（R4 Phase 4.5 处理 ATS 硬化）。
set -euo pipefail

IPA="${1:?usage: verify_ipa.sh <ipa>}"
[ -f "$IPA" ] || { echo 'IPA VERIFY: FAIL (file not found)'; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"

APP_DIR="$(find "$WORK" -maxdepth 3 -type d -name '*.app' | head -1)"
if [ -z "$APP_DIR" ]; then echo 'IPA VERIFY: FAIL (no .app under Payload)'; exit 1; fi

# 解释器探测：优先 python3；不可用（如 Windows Store 空壳 stub）回退 python
PYBIN="$(command -v python3 || true)"
if [ -z "$PYBIN" ] || ! "$PYBIN" -c 'import sys' 2>/dev/null; then
  PYBIN="$(command -v python)"
fi
[ -n "$PYBIN" ] || { echo 'IPA VERIFY: FAIL (no python interpreter)'; exit 1; }

"$PYBIN" - "$APP_DIR" <<'PY'
import fnmatch
import os
import re
import sys

app = sys.argv[1]
fail = False

BAD_EXT = ("*.txt", "*.md", "*.env", "mysql*", "*.db",
           "*.sqlite", "*.sqlite3", "*.sql", "*.sqliteres")

TOP_ALLOWED = {"Info.plist", "JDLV", "PkgInfo", "Assets.car", "embedded.mobileprovision"}


def allowed(rel):
    parts = rel.replace("\\", "/").split("/")
    if len(parts) == 1:
        # R5 P3：actool 对单尺寸 AppIcon.appiconset 会在 IPA 根部落 AppIcon*.png
        #（资源编译器产物，非白名单外杂物 —— run 43566448663 首次过滤运行执行到本门禁暴露）
        if parts[0].startswith("AppIcon") and parts[0].endswith(".png"):
            return True
        return parts[0] in TOP_ALLOWED
    top = parts[0]
    if top == "Frameworks" and len(parts) >= 2 and parts[1].endswith(".framework"):
        return True
    if top.endswith(".bundle"):
        return True
    if top == "_CodeSignature":
        return True
    if parts[-1] == "PrivacyInfo.xcprivacy":
        return True
    return False


PATTERNS = [
    ("password_assign", re.compile(r"(?i)password\s*[:=]\s*[\"'][^\"'\r\n\x00]{1,96}[\"']", re.DOTALL)),
    ("mysql_url_creds", re.compile(r"(?i)mysql://[^\s:]+:[^\s@]+@")),
    ("jdbc_mysql", re.compile(r"(?i)jdbc:mysql")),
]


def scan_bytes(data):
    hits = []
    for name, rx in PATTERNS:
        for m in rx.finditer(data.decode("utf-8", "ignore")):
            hits.append((name, "ascii", m.start(), len(m.group(0))))
    for enc in ("utf-16-le", "utf-16-be"):
        for shift in (0, 1):
            chunk = data[shift:]
            if len(chunk) < 2:
                continue
            text = chunk.decode(enc, errors="ignore")
            for name, rx in PATTERNS:
                for m in rx.finditer(text):
                    hits.append((name, enc.replace("-", ""), shift + m.start() * 2, len(m.group(0))))
    return hits


print("== VERIFY IPA: %s ==" % os.path.basename(app))
files = []
for dirpath, _dirs, fns in os.walk(app):
    for fn in fns:
        rel = os.path.relpath(os.path.join(dirpath, fn), app)
        files.append(rel)

# 1) 坏扩展名（无论白名单与否，一律 FAIL）
for rel in sorted(files):
    base = os.path.basename(rel).lower()
    if any(fnmatch.fnmatch(base, pat) for pat in BAD_EXT):
        fail = True
        print("BAD-EXT %s" % rel)

# 2) 白名单
for rel in sorted(files):
    if not allowed(rel):
        fail = True
        print("NOT-ALLOWED %s" % rel)

# 3) Info.plist 信息 + ATS 警告（不拦截）
info = os.path.join(app, "Info.plist")
try:
    import plistlib
    with open(info, "rb") as f:
        pl = plistlib.load(f)
    ats = pl.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoads") is True:
        print("WARN NSAllowsArbitraryLoads=true (Phase 4.5 will harden ATS)")
    print("INFO version=%s(%s) icons=%s" % (
        pl.get("CFBundleShortVersionString"), pl.get("CFBundleVersion"),
        "present" if ("CFBundleIcons" in pl or "CFBundleIconName" in pl) else "ABSENT"))
except Exception as e:
    print("WARN Info.plist unreadable: %s" % type(e).__name__)

# 4) 口令模式扫描（全文件，覆盖 Mach-O ASCII/UTF-16）
hits = 0
for dirpath, _dirs, fns in os.walk(app):
    for fn in fns:
        p = os.path.join(dirpath, fn)
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        rel = os.path.relpath(p, app)
        for name, enc, off, mlen in scan_bytes(data):
            hits += 1
            fail = True
            print("SECRET-HIT file=%s encoding=%s pattern=%s offset=0x%x match_len=%d"
                  % (rel, enc, name, off, mlen))

# 5) 已知密钥值比对
env_path = os.environ.get("JDLV_KNOWN_SECRETS_FILE")
if env_path and os.path.exists(env_path):
    with open(env_path, "r", encoding="utf-8", errors="ignore") as f:
        known = [ln.rstrip("\r\n") for ln in f if ln.strip()]
    khits = 0
    for dirpath, _dirs, fns in os.walk(app):
        for fn in fns:
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            rel = os.path.relpath(p, app)
            for idx, sec in enumerate(known):
                for enc in ("utf-8", "utf-16-le", "utf-16-be"):
                    needle = sec.encode(enc, "ignore")
                    start = 0
                    while True:
                        pos = data.find(needle, start)
                        if pos < 0:
                            break
                        khits += 1
                        fail = True
                        print("KNOWN-HIT file=%s secret_index=%d encoding=%s offset=0x%x length=%d"
                              % (rel, idx, enc, pos, len(needle)))
                        start = pos + 1
    print("KNOWN-SECRETS checked=%d hits=%d" % (len(known), khits))
else:
    print("KNOWN-SECRETS skipped (JDLV_KNOWN_SECRETS_FILE not set)")

if fail:
    print("IPA VERIFY: FAIL")
    sys.exit(1)
print("IPA VERIFY: PASS")
PY
