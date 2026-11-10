#!/usr/bin/env bash
# R4 P2/P8：构建资源树门禁（规划 §5.2；任务 10 V5）。
# 在 CI「Generate project」前跑：JDLV/ 源树出现任何敏感形态文件 → 直接失败。
# （project.yml excludes 是第一道；本脚本是独立二道 —— XcodeGen excludes 不是安全边界。）
set -euo pipefail

cd "$(dirname "$0")/.."

hits=$(find JDLV -type f \( \
  -name '*.txt' -o -name '*.secret' -o -name '*.credentials' \
  -o -name 'mysql*' -o -name '.env*' -o -name '*.sql' -o -name '*.db' \
  -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.log' \) 2>/dev/null || true)
[ -z "$hits" ] || { echo 'resource-tree FAIL: sensitive files under JDLV/'; echo "$hits"; exit 1; }
echo 'resource-tree OK'
