#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R5 P4 §3：layout-report.json 独立校验（最小门槛）。

用法:
  python -I scripts/verify_layout_report.py <layout-report.json> [--min-pages N]

校验（不要只检查文件存在）:
  1. JSON 可解析；
  2. "violations" 为数组且为空（布局违规 = 失败）；
  3. "skippedPages" 为数组（缺席页须在 blockers 说明中列明，如 top250/blocker B1）；
  4. "pagesAudited" 为数组且长度 >= --min-pages（默认 9 = 10 页 - blocker B1 top250）。

退出码 0 = 通过；1 = 有不达标项。
"""
import sys
import json
import argparse


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--min-pages", type=int, default=9)
    args = ap.parse_args()

    try:
        with open(args.report, encoding="utf-8") as f:
            payload = json.load(f)
    except Exception as e:
        print("FAIL parse: %s" % e)
        return 1

    if not isinstance(payload, dict):
        print("FAIL shape: top-level must be an object")
        return 1

    violations = payload.get("violations")
    if not isinstance(violations, list):
        print("FAIL shape: violations must be a list")
        return 1
    if violations:
        print("FAIL violations=%d" % len(violations))
        for v in violations[:10]:
            print("  - [%s] %s: %s" % (v.get("page"), v.get("element"), v.get("violation")))
        return 1

    skipped = payload.get("skippedPages")
    if not isinstance(skipped, list):
        print("FAIL shape: skippedPages must be a list")
        return 1
    if skipped:
        print("NOTE skippedPages=%s（缺席页须在 blockers/验收报告中列明）" % skipped)

    pages = payload.get("pagesAudited")
    if not isinstance(pages, list):
        print("FAIL shape: pagesAudited must be a list（R5 P4 起报告携带）")
        return 1
    if len(pages) < args.min_pages:
        print("FAIL pages audited %d < min %d" % (len(pages), args.min_pages))
        return 1

    print("RESULT: PASS (pages=%d skipped=%s violations=0)" % (len(pages), skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
