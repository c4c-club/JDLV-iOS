#!/usr/bin/env bash
# 仓库合规门禁（R10/C5/C9：与 .github/workflows/ios.yml 的 guard job 共用同一段逻辑，
# 原样复制、禁止两处各写一套；本地可跑）。
#
# 统一强模式：只认「引号包裹的口令字面量」（不误报 self.password = password 之类赋值、
# 不误报 CI 合成的无引号 root 变量）；显式判空（禁止 `! grep … | grep -q .` 假绿 ——
# set -e 下 `! true` 不中断，命中仍打印 guard OK、exit 0）。
# 本地 docs/ 合法存在（gitignored 证据区）：用 `git ls-files docs | wc -l == 0` +
# `git check-ignore -q docs/` 判定；docs 凭据扫描不排除（07_证据 为只读冻结区，豁免）。
# 自匹配规避统一用 `JDLV-Mobile/app/sr[c]` 字符类，不排除 .github。
set -euo pipefail

cd "$(dirname "$0")/.."

PAT="(PASSWORD|PASS|password|store[P]assword|key[P]assword)[[:space:]]*[:=][[:space:]]*[\"']"
DOC_RE='(^|/)(README|CHANGELOG|LICENSE)|\.(md|txt|kt|gradle.*)$|(^|/)docs/'
doc_hits=$(git ls-files | grep -Ei "$DOC_RE" | grep -vE '^scripts/secret_allowlist\.txt$' || true)
[ -z "$doc_hits" ] || { echo 'guard FAIL: tracked doc files'; echo "$doc_hits"; exit 1; }
[ "$(git ls-files docs | wc -l)" -eq 0 ] || { echo 'guard FAIL: docs tracked'; exit 1; }
android_hits=$(git ls-files | grep -E 'JDLV-Mobile/app/sr[c]' || true)
[ -z "$android_hits" ] || { echo 'guard FAIL: Android sources'; echo "$android_hits"; exit 1; }
# R4 良性形态过滤（两处 guard 同步）：ALLOW_EMPTY 开关行，以及 PASS 键取值为
# openssl rand 命令替换（运行时随机生成 + add-mask，非字面量）的行。
BENIGN="MYSQL_ALLOW_EMPTY_PASSWORD|PASS[A-Z_]*[[:space:]]*[:=][[:space:]]*\"\"|PASS[A-Z_]*[[:space:]]*=[[:space:]]*[\"']\\$\(openssl rand"
cred_hits=$(git grep -InE "$PAT" -- . | grep -vE "$BENIGN" | cut -d: -f1 | sort -u || true)
[ -z "$cred_hits" ] || { echo 'guard FAIL: credential literals in tracked tree'; echo "$cred_hits"; exit 1; }
# R4 强模式 2：值形态凭据（排除 $VAR 引用 / 空串 / ALLOW_EMPTY 开关；
#  mysql URL 限定常见用户名字符，规避扫描器源码自匹配）
RPAT="(IDENTIFIED[[:space:]]+.*BY[[:space:]]*[\"'][^\"'\$]|[A-Z_]*PASSWORD[[:space:]]*[:=][[:space:]]*[\"'][^\"'\$]|TEST_RUNNER_[A-Z_]*PASS[A-Z_]*[[:space:]]*[:=][[:space:]]*[\"'][^\"'\$]|mysql://[A-Za-z0-9._%~+-]+:[^[:space:]@]+@)"
rcred_hits=$(git grep -InE "$RPAT" -- . | grep -vE "$BENIGN" | cut -d: -f1 | sort -u || true)
[ -z "$rcred_hits" ] || { echo 'guard FAIL: credential value literals in tracked tree'; echo "$rcred_hits"; exit 1; }
if [ -d docs ]; then
  doccred=$(grep -rInE "$PAT" docs --exclude-dir=07_证据 2>/dev/null | grep -vE "$BENIGN" | cut -d: -f1 | sort -u || true)
  [ -z "$doccred" ] || { echo 'guard FAIL: credential literals in local docs/'; echo "$doccred"; exit 1; }
  git check-ignore -q docs/ || { echo 'guard FAIL: docs/ not gitignored'; exit 1; }
fi
grep -q 'MARKETING_VERSION: 1.6.0' project.yml || { echo 'guard FAIL: version'; exit 1; }
# R3 门禁：键盘 API 审计（问题 1 —— asciiCapable/inputView/UIKeyInput 禁用）
kb_hits=$(grep -R -E "asciiCapable|inputView|UIKeyInput" JDLV --include='*.swift' || true)
[ -z "$kb_hits" ] || { echo 'guard FAIL: banned keyboard API (issue 1 audit)'; echo "$kb_hits"; exit 1; }
echo 'keyboard audit: 0 hits'
echo 'guard OK'
