#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Derive the known-leaked credential value list from git history (R6).

Scans every blob reachable via git cat-file --batch-all-objects with the
scan_repo_secrets value-extraction patterns, collects every non-structural
value, and writes:
  --values-out FILE  raw values, one per line (RUNTIME-ONLY, never commit)
  --hashes-out FILE  sha256[:16] of each unique value (optional)

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


def collect_values(root):
    check = git(root, "cat-file", "--batch-all-objects",
                "--batch-check=%(objecttype) %(objectname) %(objectsize)"
                ).decode("utf-8", "ignore")
    blobs = [ln.split()[1] for ln in check.splitlines() if ln.startswith("blob ")]
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
                    if val.strip():
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
    values = collect_values(root)
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
