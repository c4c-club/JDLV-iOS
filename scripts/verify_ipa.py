#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Release IPA security gate (R6 Phase 1 rewrite of the old verify_ipa.sh).

Checks, in order:
  1. bundle file whitelist + bad extensions + seed/fixture file names
  2. byte-level scan of every bundle file (ASCII/UTF-8/UTF-16, plist key/value,
     embedded archives) via scan_repo_secrets patterns
  3. known leaked values: raw-value needle search (utf-8/utf-16) over every
     bundle file + hash comparison against every scan hit

Verdict (last line, exact):
  IPA VERIFY: PASS             -- all checks ran clean (known checks included)
  IPA VERIFY: PASS-INCOMPLETE  -- clean, but no known-secret inputs were
                                  provided; NOT accepted as a release pass
  IPA VERIFY: FAIL             -- violations listed above (paths/offsets/
                                  lengths/hashes only; values never printed)

Usage:
  python verify_ipa.py <JDLV-unsigned.ipa | Payload dir | .app dir>
      [--known-values FILE] [--known-hashes FILE] [--out FILE]

Known inputs come from the environment only (derive_known_hashes.py output
and/or a user-provided list); they are never committed to the repository.
A missing known-secret input can never yield a plain PASS (fail-closed).
"""

import argparse
import fnmatch
import os
import plistlib
import shutil
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_repo_secrets as SC

BAD_EXT = ("*.txt", "*.md", "*.env", "mysql*", "*.db", "*.sqlite",
           "*.sqlite3", "*.sql", "*.sqliteres")
TOP_ALLOWED = {"Info.plist", "JDLV", "PkgInfo", "Assets.car",
               "embedded.mobileprovision"}
SEED_NAME_MARKERS = ("seed", "fixture")
NEEDLE_MIN_LEN = 8


def fnmatch_base(rel, pat):
    return fnmatch.fnmatch(os.path.basename(rel).lower(), pat)


def bundle_allowed(rel):
    parts = rel.replace("\\", "/").split("/")
    if len(parts) == 1:
        if parts[0].startswith("AppIcon") and parts[0].endswith(".png"):
            return True
        return parts[0] in TOP_ALLOWED
    top = parts[0]
    if top == "Frameworks" and len(parts) >= 2 and parts[1].endswith(".framework"):
        return True
    # R7-P7：Xcode 26 起 Swift 5 源码产物也会带 back-deploy 兼容 shim
    # （Frameworks/libswiftCompatibilitySpan.dylib 等, 官方运行时, run 44805049841
    # verify FAIL 证据）—— 裸 libswift*.dylib 与 *.framework 同为可解释内容。
    if top == "Frameworks" and len(parts) == 2 and parts[1].startswith("libswift"):
        return True
    if top.endswith(".bundle"):
        return True
    if top == "_CodeSignature":
        return True
    if parts[-1] == "PrivacyInfo.xcprivacy":
        return True
    return False


def resolve_app(target, work_root):
    """Return (app_dir, temp_dir_or_None) or (None, None) with a reason."""
    if os.path.isdir(target):
        if target.endswith(".app"):
            return target, None
        hits = []
        for dirpath, dirnames, filenames in os.walk(target):
            for d in dirnames:
                if d.endswith(".app"):
                    hits.append(os.path.join(dirpath, d))
        if len(hits) == 1:
            return hits[0], None
        return None, "no/multiple .app under directory (%d found)" % len(hits)
    if not os.path.isfile(target):
        return None, "input not found"
    with open(target, "rb") as f:
        magic = f.read(4)
    if magic != b"PK\x03\x04":
        return None, "not a zip/ipa and not a directory"
    ex = os.path.join(work_root, "ex")
    with zipfile.ZipFile(target) as zf:
        zf.extractall(ex)
    hits = []
    for dirpath, dirnames, filenames in os.walk(ex):
        for d in dirnames:
            if d.endswith(".app"):
                hits.append(os.path.join(dirpath, d))
    if len(hits) == 1:
        return hits[0], ex
    return None, "no/multiple .app under Payload (%d found)" % len(hits)


def load_known_values(path):
    out = []
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for ln in f:
                v = ln.rstrip("\r\n")
                if v:
                    out.append(v)
    return out


def load_known_hashes(path):
    return SC.load_known_hashes(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--known-values", default=None,
                    help="runtime-only file with known leaked raw values")
    ap.add_argument("--known-hashes", default=None,
                    help="file with sha256[:16] hex of known leaked values")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    lines = []
    fail = False
    work = tempfile.mkdtemp(prefix="verify_ipa_r6_")
    try:
        app, err = resolve_app(args.target, work)
        if app is None:
            print("IPA VERIFY: FAIL (%s)" % err)
            return 1
        lines.append("== VERIFY IPA: %s ==" % os.path.basename(app))

        files = []
        for dirpath, dirnames, filenames in os.walk(app):
            for fn in filenames:
                files.append(os.path.relpath(os.path.join(dirpath, fn), app))

        # 1) structure gates
        for rel in sorted(files):
            base = os.path.basename(rel).lower()
            if any(fnmatch_base(rel, p) for p in BAD_EXT):
                fail = True
                lines.append("BAD-EXT %s" % rel)
            low = base.lower()
            if any(m in low for m in SEED_NAME_MARKERS):
                fail = True
                lines.append("SEED-FILE %s" % rel)
        for rel in sorted(files):
            if not bundle_allowed(rel):
                fail = True
                lines.append("NOT-ALLOWED %s" % rel)

        # 2) content scan (scanner patterns incl. plist cred keys)
        scan_hits = []
        for rel in sorted(files):
            p = os.path.join(app, *rel.split("/"))
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            recs = SC.scan_container(data, rel, 0, [], frozenset())
            for r in recs:
                if r["label"] in ("HIT", "KNOWN-LEAK"):
                    scan_hits.append(r)
                    fail = True
                    lines.append(
                        "SECRET-HIT file=%s enc=%s line=%d off=%d pattern=%s len=%d hash=%s"
                        % (rel, r["enc"], r["line"], r["off"], r["pattern"],
                           r["len"], r["hash"]))

        # 3) Info.plist readability + ATS warning (non-blocking)
        info = os.path.join(app, "Info.plist")
        try:
            with open(info, "rb") as f:
                pl = plistlib.load(f)
            ats = pl.get("NSAppTransportSecurity") or {}
            if ats.get("NSAllowsArbitraryLoads") is True:
                lines.append("WARN NSAllowsArbitraryLoads=true (hardening tracked)")
            lines.append("INFO version=%s(%s)" % (
                pl.get("CFBundleShortVersionString"), pl.get("CFBundleVersion")))
        except Exception as e:
            fail = True
            lines.append("FAIL Info.plist unreadable: %s" % type(e).__name__)

        # 4) known leaked values
        known_values = load_known_values(args.known_values)
        known_hashes = load_known_hashes(args.known_hashes)
        needle_values = [v for v in known_values if len(v) >= NEEDLE_MIN_LEN]
        known_hits = 0
        for rel in sorted(files):
            p = os.path.join(app, *rel.split("/"))
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            for v in needle_values:
                for enc in ("utf-8", "utf-16-le", "utf-16-be"):
                    needle = v.encode(enc, "ignore")
                    if not needle:
                        continue
                    start = 0
                    while True:
                        pos = data.find(needle, start)
                        if pos < 0:
                            break
                        known_hits += 1
                        fail = True
                        lines.append(
                            "KNOWN-HIT file=%s encoding=%s offset=0x%x length=%d"
                            % (rel, enc, pos, len(needle)))
                        start = pos + 1
        hash_hits = 0
        for r in scan_hits:
            if r["hash"] in known_hashes:
                hash_hits += 1
                fail = True
                lines.append("KNOWN-HIT-BY-HASH file=%s pattern=%s hash=%s"
                             % (r["path"], r["pattern"], r["hash"]))
        lines.append("KNOWN-SECRETS values=%d needles=%d hashes=%d byte_hits=%d hash_hits=%d"
                     % (len(known_values), len(needle_values), len(known_hashes),
                        known_hits, hash_hits))

        if fail:
            lines.append("IPA VERIFY: FAIL")
            verdict = "FAIL"
        elif known_values or known_hashes:
            lines.append("IPA VERIFY: PASS")
            verdict = "PASS"
        else:
            lines.append("IPA VERIFY: PASS-INCOMPLETE (known-secret check skipped; not a release pass)")
            verdict = "PASS-INCOMPLETE"

        report = "\n".join(lines) + "\n"
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(report)
        # R6：FAIL 时全量明细进 stdout（仅路径/偏移/长度/哈希，值永不打印）——
        # 修复 CI 只见 verdict 不见明细的诊断盲区（run 43755497265 实证）。
        if fail:
            print(report)
        else:
            print(report.splitlines()[-1])
        return {"FAIL": 1, "PASS": 0, "PASS-INCOMPLETE": 2}[verdict]
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
