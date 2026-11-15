#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Classification-manifest gate for scan_repo_secrets reports (R6).

Every HIT/KNOWN-LEAK line must carry a value hash (sha256[:16]) that is listed
in scripts/secret_classification.txt together with a non-production category
and a justification, and the hit path must match the entry's path regex.
Unclassified hits fail the gate, so a NEW hardcoded credential anywhere
(production or test) breaks CI until it is classified by a human decision.

Manifest line format:
  <hash16> <category> <path_regex> # reason: <why this is not a production value>

Allowed categories: test-fixture, key-name, ui-label, scanner-source,
ci-synthetic, evidence-local. The category "production" is deliberately not
allowed: a real production credential must be rotated/removed, not classified.

Usage:
  python check_hits_manifest.py --report R1 [--report R2 ...] \
      --manifest scripts/secret_classification.txt
Exit 0 = all hits classified; exit 1 = unclassified hits or bad manifest.
"""

import argparse
import re
import sys

ALLOWED_CATEGORIES = {
    "test-fixture", "key-name", "ui-label", "scanner-source",
    "ci-synthetic", "evidence-local",
}


def parse_manifest(path):
    entries = {}
    errors = []
    with open(path, "r", encoding="utf-8") as f:
        for ln_no, ln in enumerate(f, 1):
            ln = ln.rstrip("\r\n")
            if not ln.strip() or ln.lstrip().startswith("#"):
                continue
            head, _sep, reason = ln.partition("# reason:")
            parts = head.strip().split(None, 2)
            if len(parts) < 3:
                errors.append("manifest line %d: need hash category path_regex" % ln_no)
                continue
            h, cat, path_rx = parts[0], parts[1], parts[2]
            if not re.match(r"^[0-9a-f]{16}$", h):
                errors.append("manifest line %d: bad hash %r" % (ln_no, h))
                continue
            if cat not in ALLOWED_CATEGORIES:
                errors.append("manifest line %d: category %r not allowed" % (ln_no, cat))
                continue
            if not reason.strip():
                errors.append("manifest line %d: missing reason" % ln_no)
                continue
            try:
                rx = re.compile(path_rx)
            except re.error as e:
                errors.append("manifest line %d: bad regex: %s" % (ln_no, e))
                continue
            entries.setdefault(h, []).append((cat, rx, path_rx, reason.strip()))
    return entries, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="append", required=True)
    ap.add_argument("--manifest", required=True)
    args = ap.parse_args()

    entries, errors = parse_manifest(args.manifest)
    if errors:
        for e in errors:
            print("MANIFEST-ERROR " + e)
        print("MANIFEST-GATE FAIL (manifest invalid)")
        return 1

    total_hits = 0
    unclassified = []
    seen = set()
    for rep in args.report:
        with open(rep, "r", encoding="utf-8") as f:
            for ln in f:
                if not (ln.startswith("HIT ") or ln.startswith("KNOWN-LEAK ")):
                    continue
                total_hits += 1
                h = None
                path = None
                for tok in ln.split(" "):
                    if tok.startswith("hash="):
                        h = tok[5:].strip()
                    elif tok.startswith("path="):
                        path = tok[5:].strip()
                if h is None or path is None:
                    unclassified.append("malformed report line: " + ln.strip())
                    continue
                key = (path, h)
                if key in seen:
                    continue
                seen.add(key)
                cands = entries.get(h, [])
                if not any(rx.search(path) for _c, rx, _p, _r in cands):
                    unclassified.append("hash=%s path=%s" % (h, path))

    if unclassified:
        for u in unclassified:
            print("UNCLASSIFIED " + u)
        print("MANIFEST-GATE FAIL hits=%d unclassified=%d" % (total_hits, len(unclassified)))
        return 1
    print("MANIFEST-GATE OK hits=%d unique=%d manifest_entries=%d"
          % (total_hits, len(seen), sum(len(v) for v in entries.values())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
