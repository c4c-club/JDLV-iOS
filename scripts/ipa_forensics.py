#!/usr/bin/env python3
"""Read-only forensics for an unpacked .app bundle (JDLV R4 Phase 0).

Outputs (to --out):
  1. File whitelist violations (*.txt/*.md/*.env/mysql*/*.db/*.sqlite*/...).
  2. Info.plist key inventory (+ notable keys).
  3. Secret-pattern hits in Mach-O ASCII/UTF-16 strings: offset + length only.
  4. Known-secret containment from $JDLV_KNOWN_SECRETS_FILE (hit / length only).

Values are NEVER printed, with or without --redact (the flag is kept for CLI
compatibility and is on by default).
"""

import argparse
import fnmatch
import os
import plistlib
import re
import sys

WHITELIST_BAD_PATTERNS = [
    "*.txt", "*.md", "*.env", "mysql*", "*.db",
    "*.sqlite", "*.sqlite3", "*.sql", "*.sqliteres",
]

TEXT_PATTERNS = [
    ("password_assign",
     r"(?i)password\s*[:=]\s*[\"'][^\"'\r\n\x00]{1,96}[\"']"),
    ("mysql_url_with_credentials",
     r"(?i)mysql://[A-Za-z0-9._%~+:-]{1,96}:[^@\s\x00\r\n]{1,96}@"),
    ("jdbc_mysql", r"(?i)jdbc:mysql"),
]

BYTE_PATTERNS = [
    (name, re.compile(p.encode("ascii", "ignore"), re.DOTALL))
    for name, p in TEXT_PATTERNS
]

MACHO_MAGICS = [
    b"\xcf\xfa\xed\xfe",  # MH_MAGIC_64 (LE)
    b"\xce\xfa\xed\xfe",  # MH_MAGIC (LE)
    b"\xca\xfe\xba\xbe",  # FAT_MAGIC (BE, on-disk bytes)
    b"\xca\xfe\xba\xbf",  # FAT_MAGIC_64 (BE)
]


def is_macho(head):
    return any(head.startswith(m) for m in MACHO_MAGICS)


def value_len(matched):
    """Length of the quoted value inside a matched literal, if determinable."""
    try:
        if isinstance(matched, str):
            s = matched
        else:
            s = matched.decode("utf-8", "ignore")
    except Exception:
        return None
    for q in ("\"", "'"):
        first = s.find(q)
        last = s.rfind(q)
        if first >= 0 and last > first:
            return last - first - 1
    return None


def iter_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            yield os.path.join(dirpath, fn)


def scan_bytes(data):
    """Return hits as (pattern, encoding, byte_offset, match_len, value_len)."""
    hits = []
    # ASCII on raw bytes
    for name, pat in BYTE_PATTERNS:
        for m in pat.finditer(data):
            hits.append((name, "ascii", m.start(), len(m.group(0)),
                         value_len(m.group(0))))
    # UTF-16LE / UTF-16BE: decode (both alignments) and run text patterns
    for enc in ("utf-16-le", "utf-16-be"):
        for shift in (0, 1):
            chunk = data[shift:]
            if len(chunk) < 2:
                continue
            try:
                text = chunk.decode(enc, errors="ignore")
            except Exception:
                continue
            for name, pat_s in TEXT_PATTERNS:
                pat = re.compile(pat_s, re.DOTALL)
                for m in pat.finditer(text):
                    hits.append((name, enc.replace("-", ""), shift + m.start() * 2,
                                 len(m.group(0)), value_len(m.group(0))))
    return hits


def scan_known(data, known):
    found = []
    for idx, secret in enumerate(known):
        for enc in ("utf-8", "utf-16-le", "utf-16-be"):
            needle = secret.encode(enc, "ignore")
            start = 0
            while True:
                pos = data.find(needle, start)
                if pos < 0:
                    break
                found.append((idx, enc, pos, len(needle)))
                start = pos + 1
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app")
    ap.add_argument("--out", required=True)
    ap.add_argument("--redact", action="store_true", default=True)
    ap.add_argument("--plist-out", default=None)
    args = ap.parse_args()

    app = os.path.abspath(args.app)
    lines = []
    lines.append("== IPA FORENSICS ==")
    lines.append("app: %s" % app)

    # 1. whitelist violations
    lines.append("")
    lines.append("== FILE WHITELIST VIOLATIONS ==")
    violations = []
    for p in iter_files(app):
        base = os.path.basename(p).lower()
        if any(fnmatch.fnmatch(base, pat) for pat in WHITELIST_BAD_PATTERNS):
            violations.append((os.path.relpath(p, app), os.path.getsize(p)))
    if violations:
        for rel, size in violations:
            lines.append("VIOLATION rel=%s size=%d" % (rel, size))
    else:
        lines.append("(none)")

    # 2. Info.plist keys
    info_plist = os.path.join(app, "Info.plist")
    notable = {}
    keys = []
    if os.path.exists(info_plist):
        with open(info_plist, "rb") as f:
            pl = plistlib.load(f)
        keys = sorted(pl.keys())
        notable["CFBundleIdentifier"] = pl.get("CFBundleIdentifier")
        notable["CFBundleShortVersionString"] = pl.get("CFBundleShortVersionString")
        notable["CFBundleVersion"] = pl.get("CFBundleVersion")
        notable["CFBundleExecutable"] = pl.get("CFBundleExecutable")
        notable["CFBundleIcons"] = "present" if "CFBundleIcons" in pl else "ABSENT"
        notable["CFBundleIconName"] = "present" if "CFBundleIconName" in pl else "ABSENT"
        ats = pl.get("NSAppTransportSecurity") or {}
        notable["NSAppTransportSecurity.NSAllowsArbitraryLoads"] = ats.get(
            "NSAllowsArbitraryLoads", "ABSENT")
    if args.plist_out:
        with open(args.plist_out, "w", encoding="utf-8") as f:
            f.write("== Info.plist keys (%d) ==\n" % len(keys))
            for k in keys:
                f.write(k + "\n")
            f.write("\n== notable ==\n")
            for k, v in sorted(notable.items()):
                f.write("%s = %s\n" % (k, v))

    lines.append("")
    lines.append("== INFO.PLIST ==")
    lines.append("keys: %d" % len(keys))
    for k, v in sorted(notable.items()):
        lines.append("%s = %s" % (k, v))

    # 3. Mach-O inventory + secret pattern scan over all files
    lines.append("")
    lines.append("== MACH-O FILES ==")
    for p in iter_files(app):
        try:
            with open(p, "rb") as f:
                head = f.read(4096)
        except OSError:
            continue
        if is_macho(head):
            lines.append("macho: %s" % os.path.relpath(p, app))

    lines.append("")
    lines.append("== SECRET PATTERN HITS (offset+length only, values redacted) ==")
    total_hits = 0
    for p in iter_files(app):
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        rel = os.path.relpath(p, app)
        macho = is_macho(data[:4096])
        for name, enc, off, mlen, vlen in scan_bytes(data):
            total_hits += 1
            lines.append("HIT file=%s macho=%s encoding=%s pattern=%s offset=0x%x match_len=%d value_len=%s"
                         % (rel, "yes" if macho else "no", enc, name, off, mlen, vlen))
    if total_hits == 0:
        lines.append("(none)")

    # 4. known secrets
    lines.append("")
    lines.append("== KNOWN SECRETS CONTAINMENT ==")
    env_path = os.environ.get("JDLV_KNOWN_SECRETS_FILE")
    if not env_path:
        lines.append("JDLV_KNOWN_SECRETS_FILE not set -> skipped")
    elif not os.path.exists(env_path):
        lines.append("JDLV_KNOWN_SECRETS_FILE=%s not found -> skipped" % env_path)
    else:
        with open(env_path, "r", encoding="utf-8", errors="ignore") as f:
            known = [ln.rstrip("\r\n") for ln in f if ln.strip()]
        total_known = 0
        for p in iter_files(app):
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            rel = os.path.relpath(p, app)
            for idx, enc, off, nlen in scan_known(data, known):
                total_known += 1
                lines.append("KNOWN-HIT file=%s secret_index=%d encoding=%s offset=0x%x length=%d"
                             % (rel, idx, enc, off, nlen))
        if total_known == 0:
            lines.append("(none, %d known secrets checked)" % len(known))

    out = "\n".join(lines) + "\n"
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(out)
    print(out)


if __name__ == "__main__":
    sys.exit(main())
