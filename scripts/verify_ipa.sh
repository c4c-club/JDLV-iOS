#!/usr/bin/env bash
# R6: thin wrapper -- the real gate is scripts/verify_ipa.py (single source).
# Usage: bash scripts/verify_ipa.sh <path/to/JDLV-unsigned.ipa | app dir>
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || true)"
if [ -z "$PYBIN" ] || ! "$PYBIN" -c 'import sys' 2>/dev/null; then
  PYBIN="$(command -v python)"
fi
[ -n "$PYBIN" ] || { echo 'IPA VERIFY: FAIL (no python interpreter)'; exit 1; }
exec "$PYBIN" -I "$DIR/verify_ipa.py" "$@"
