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

grep -q 'MARKETING_VERSION: 1.7.0' project.yml || { echo 'guard FAIL: version'; exit 1; }

# P0 gate 1: workflows must never upload public build artifacts (.ipa/.app.zip);
# every upload-artifact step must stay free of bundle paths (public repo rule)
wf_ipa=$(awk '
  /actions\/upload-artifact/ { blk = 1; next }
  /^      - [a-zA-Z]/ || /^  [a-zA-Z0-9_-]+:/ { blk = 0 }
  blk && (/\.ipa/ || /\.app\.zip/) { print FILENAME ": " $0 }
' .github/workflows/*.yml)
[ -z "$wf_ipa" ] || { echo 'guard FAIL: workflow uploads public build artifact'; echo "$wf_ipa"; exit 1; }
echo 'workflow artifact gate: no .ipa/.app.zip uploads'

# P0 gate 2: release must be human-approved (environment: release) and draft-first
grep -q 'environment: release' .github/workflows/ios.yml || { echo 'guard FAIL: release not environment-gated'; exit 1; }
grep -q -- '--draft' .github/workflows/ios.yml || { echo 'guard FAIL: release not draft-first'; exit 1; }
echo 'release gate: environment: release + draft flow present'

# P0 gate 3 (version drift, P8 pending): compare project.yml MARKETING_VERSION
# against the R7 target when docs/28 is locally present (gitignored, so CI runs
# without it). Mismatch before P8 is a WARN, not a gate failure.
if [ -f 'docs/28_分段执行_R7/00_MASTER.md' ]; then
  r7_target=$(grep -oE '版本 [0-9]+\.[0-9]+\.[0-9]+' 'docs/28_分段执行_R7/00_MASTER.md' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  r7_cur=$(grep -oE 'MARKETING_VERSION: [0-9.]+' project.yml | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -n "$r7_target" ] && [ -n "$r7_cur" ] && [ "$r7_cur" != "$r7_target" ]; then
    echo "guard WARN: MARKETING_VERSION $r7_cur != R7 target $r7_target (bump scheduled in P8)"
  fi
fi

# R3 gate: keyboard API audit (asciiCapable/inputView/UIKeyInput banned)
kb_hits=$(grep -R -E "asciiCapable|inputView|UIKeyInput" JDLV --include='*.swift' || true)
[ -z "$kb_hits" ] || { echo 'guard FAIL: banned keyboard API (issue 1 audit)'; echo "$kb_hits"; exit 1; }
echo 'keyboard audit: 0 hits'
echo 'guard OK'
