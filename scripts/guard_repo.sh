#!/usr/bin/env bash
# 仓库合规门禁（与 .github/workflows/ios.yml 的 guard job 同逻辑，本地可跑）。
# 注：模式串用 [x] 字符类避免脚本自匹配；本地排除 docs/（仅本地证据区，.gitignore 已排除、不入仓库）。
set -e

cd "$(dirname "$0")/.."

test ! -f README.md
! find . \( -name '*.md' -o -name '*.txt' \) -not -path './.git/*' -not -path './docs/*' | grep -q .
! find . \( -name '*.kt' -o -name '*.gradle*' \) | grep -q .
! grep -ril 'JDLV-Mobile/app/sr[c]' . --exclude-dir=.git --exclude-dir=docs
! grep -rilE 'store[P]assword|key[P]assword|password[[:space:]]*=' . --exclude-dir=.git --exclude-dir=docs
grep -q 'MARKETING_VERSION: 1.6.0' project.yml

echo 'guard OK'
