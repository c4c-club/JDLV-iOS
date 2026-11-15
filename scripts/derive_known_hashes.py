#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Derive the known-leaked credential value list from git history (R6).

Scans every blob REACHABLE from refs (git rev-list --all) with the
scan_repo_secrets value-extraction patterns, collects every non-structural
value, and writes:
  --values-out FILE  raw values, one per line (RUNTIME-ONLY, never commit)
  --hashes-out FILE  sha256[:16] of each unique value (optional)

R6 修正（CI run 43763473239 IPA 门禁 46 误报 KNOWN-HIT 实证）：
  1. 只扫可达引用（rev-list --all）—— --batch-all-objects 会把 dangling 对象
     一并捞入，其值从不在 head/history 报告中出现、也就不在分类清单里；
  2. 排除已被 scripts/secret_classification.txt 分类为非生产的值（按值哈希
     查清单；清单只含哈希+类别，不含值，仓库不落密文）。分类清单类别集合
     不含 production —— 在清单里 = 证明非生产（test-fixture/ui-label/...
     这些字符串本就合法存在于应用二进制）；未分类值保留为 needle
     （fail-closed：未分类 = 视同生产泄露，IPA 命中必须处理）。

Raw values are never printed and must never be written inside the repository
tree; callers use a temp dir or the gitignored evidence directory.

Usage:
  python derive_known_hashes.py --root . --values-out /tmp/known.values \
      [--hashes-out /tmp/known.sha256] [--extra-values FILE] [--min-needle 8]
"""

import argparse
import hashlib
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_repo_secrets as SC


def git(root, *args):
    r = subprocess.run(["git", "-C", root] + list(args), capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args),
                                                  r.stderr.decode("utf-8", "ignore")[:400]))
    return r.stdout


def load_nonproduction_hashes(root):
    """分类清单（哈希 → 非生产类别）；类别集合不含 production，在清单 = 非生产。"""
    import io
    out = set()
    path = os.path.join(root, "scripts", "secret_classification.txt")
    if not os.path.exists(path):
        return out
    for ln in io.open(path, encoding="utf-8"):
        p = ln.split()
        if len(p) >= 2 and not p[0].startswith("#"):
            out.add(p[0].strip())
    return out


def collect_values(root, skip_hashes=frozenset()):
    """只取 refs 可达 blob 的非结构性值（排除已分类非生产）。"""
    revs = git(root, "rev-list", "--all").decode("utf-8", "ignore").split()
    blobs = set()
    for rev in revs:
        ls = git(root, "ls-tree", "-r", "--format=%(objectname)", rev
                 ).decode("utf-8", "ignore").splitlines()
        for sha in ls:
            s = sha.strip()
            if s:
                blobs.add(s)
    blobs = sorted(blobs)
    p = subprocess.Popen(
        ["git", "-C", root, "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def feed():
        try:
            for sha in blobs:
                p.stdin.write((sha + "\n").encode())
                p.stdin.flush()
        except (BrokenPipeError, ValueError, OSError):
            pass
        finally:
            try:
                p.stdin.close()
            except (BrokenPipeError, OSError):
                pass

    import threading
    t = threading.Thread(target=feed, daemon=True)
    t.start()
    values = set()
    try:
        for _ in blobs:
            header = p.stdout.readline().decode("ascii", "ignore").split()
            if len(header) < 3:
                continue
            _sha, _typ, size = header[0], header[1], int(header[2])
            data = p.stdout.read(size)
            p.stdout.read(1)
            if not bytes_look_relevant_data(data):
                continue
            text = data.decode("utf-8", "ignore")
            for line in text.split("\n"):
                for _pat, val, _col in SC.scan_line(line, allow_bare=True):
                    structural, _tag = SC.classify_value(val)
                    if structural:
                        continue
                    if val.strip() and SC.value_hash(val) not in skip_hashes:
                        values.add(val)
    finally:
        t.join(timeout=10)
        p.wait()
    return values


def bytes_look_relevant_data(data):
    return SC.bytes_look_relevant(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--values-out", required=True)
    ap.add_argument("--hashes-out", default=None)
    ap.add_argument("--extra-values", default=None,
                    help="optional user-provided values merged in (never printed)")
    ap.add_argument("--min-needle", type=int, default=8,
                    help="minimum value length for byte-level needle search")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    skip = load_nonproduction_hashes(root)
    values = collect_values(root, skip)
    if args.extra_values and os.path.exists(args.extra_values):
        with open(args.extra_values, "r", encoding="utf-8", errors="ignore") as f:
            for ln in f:
                v = ln.rstrip("\r\n")
                if v:
                    values.add(v)

    ordered = sorted(values)
    os.makedirs(os.path.dirname(os.path.abspath(args.values_out)) or ".", exist_ok=True)
    with open(args.values_out, "w", encoding="utf-8") as f:
        for v in ordered:
            f.write(v + "\n")
    needle_count = sum(1 for v in ordered if len(v) >= args.min_needle)
    if args.hashes_out:
        with open(args.hashes_out, "w", encoding="utf-8") as f:
            for v in ordered:
                f.write(SC.value_hash(v) + "\n")
    print("KNOWN-VALUES derived=%d unique=%d needle_eligible=%d (values never printed)"
          % (len(values), len(ordered), needle_count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
