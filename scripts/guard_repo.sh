#!/usr/bin/env bash
# R6 repo compliance gate — single source of truth; the CI guard job runs
# THIS file directly (no duplicated inline logic anymore).
# Credential scanning is delegated to scripts/scan_repo_secrets.py
# (structural-only allowlist) + scripts/check_hits_manifest.py (hash-based
# classification manifest). Local docs/ evidence is covered by the phase-level
# docs scan recorded under docs/27_证据_R6 (docs/ is gitignored and
# \`git ls-files docs\` must stay 0; tracked-tree scanning runs here).
set -euo pipefail
cd "$(dirname "$0")/.."

PYBIN="$(command -v python3 || true)"
if [ -z "$PYBIN" ] || ! "$PYBIN" -c 'import sys' 2>/dev/null; then
  PYBIN="$(command -v python)"
fi
[ -n "$PYBIN" ] || { echo 'guard FAIL: no python interpreter'; exit 1; }

# docs/ must never enter the repo
[ "$(git ls-files docs | wc -l)" -eq 0 ] || { echo 'guard FAIL: docs tracked'; exit 1; }
if [ -d docs ]; then
  git check-ignore -q docs/ || { echo 'guard FAIL: docs/ not gitignored'; exit 1; }
fi

# tracked doc-type files stay forbidden (docs live in gitignored docs/)
DOC_RE='(^|/)(README|CHANGELOG|LICENSE)|\.(md|txt|kt|gradle.*)$'
doc_hits=$(git ls-files | grep -Ei "$DOC_RE" | grep -vE '^scripts/(secret_allowlist|secret_classification)\.txt$' || true)
[ -z "$doc_hits" ] || { echo 'guard FAIL: tracked doc files'; echo "$doc_hits"; exit 1; }

android_hits=$(git ls-files | grep -E 'JDLV-Mobile/app/sr[c]' || true)
[ -z "$android_hits" ] || { echo 'guard FAIL: Android sources'; echo "$android_hits"; exit 1; }

# head secret scan + classification gate (any NEW non-structural value must
# be classified in scripts/secret_classification.txt or the gate fails)
"$PYBIN" -I scripts/scan_repo_secrets.py --root . --mode head --out /tmp/r6-guard-head.txt
"$PYBIN" -I scripts/check_hits_manifest.py --report /tmp/r6-guard-head.txt --manifest scripts/secret_classification.txt

grep -q 'MARKETING_VERSION: 1.6.1' project.yml || { echo 'guard FAIL: version'; exit 1; }

# R3 gate: keyboard API audit (asciiCapable/inputView/UIKeyInput banned)
kb_hits=$(grep -R -E "asciiCapable|inputView|UIKeyInput" JDLV --include='*.swift' || true)
[ -z "$kb_hits" ] || { echo 'guard FAIL: banned keyboard API (issue 1 audit)'; echo "$kb_hits"; exit 1; }
echo 'keyboard audit: 0 hits'
echo 'guard OK'
