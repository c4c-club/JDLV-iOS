#!/usr/bin/env python3
"""Secret scan for JDLV R4 (Phase 0 baseline; Phase 1/2 gates).

Modes:
  head     git grep over tracked files (working tree HEAD)
  history  every blob in the object DB (git cat-file --batch-all-objects),
           path mapping via git rev-list --objects --all
  docs     recursive scan of --root (default docs/), skipping binaries and
           any path containing 07_证据
  ipa      recursive scan of --root treated as a plain directory (unpacked app)

Strong-value patterns only (they match secret VALUES, not key names alone).
Output is always redacted: file:line / object / offset + lengths. Values are
never printed. --redact is kept for CLI compatibility and is on by default.
"""

import argparse
import os
import re
import subprocess
import sys

PATTERNS = [
    # (name, python_regex, grep_hint)
    # grep_hint: a loose POSIX-ERE filter for `git grep -E` in head mode.
    # POSIX ERE does not support \s inside bracket expressions, so the hint
    # must stay engine-agnostic; the python_regex is the authoritative
    # matcher for every mode.
    ("password_assign", r"(password|passwd|pwd)\s*[:=]\s*[\"'][^\"']{3,}[\"']",
     "(password|passwd|pwd)"),
    ("sql_identified_by", r"IDENTIFIED\s+(WITH\s+\S+\s+)?BY\s+[\"'][^\"']+[\"']",
     "IDENTIFIED"),
    ("mysql_env_password", r"MYSQL_[A-Z_]*PASSWORD\s*[:=]\s*\S+",
     "MYSQL_"),
    ("runner_env_pass", r"(TEST_RUNNER_|JDLV_)[A-Z_]*PASS\s*[:=]\s*\S+",
     "PASS"),
    ("mysql_url_creds", r"mysql://[^\s:]+:[^\s@]+@",
     "mysql://"),
    ("jdbc_mysql", r"jdbc:mysql", "jdbc:mysql"),
    ("private_key_block", r"BEGIN [A-Z ]*PRIVATE KEY", "PRIVATE KEY"),
]

DOCS_EXCLUDE_SUBSTR = "07_证据"

# Synthetic (non-credential) value forms, exempted narrowly:
#
# 1. CI-only keys whose value is the per-run ephemeral github.run_id
#    expression (exact unquoted form). Any other key or any other
#    expression still hits; a real literal always hits.
# 2. The fixture/docs placeholder token __SET_IN_CI__ as the entire value
#    (optionally quoted): synthetic by construction, not a credential.
SYNTHETIC_RUN_ID = re.compile(
    r"(MYSQL_ROOT_PASSWORD|JDLV_TEST_MYSQL_PASS)\s*[:=]\s*"
    r"\$\{\{\s*github\.run_id\s*\}\}\s*$"
)
PLACEHOLDER_SET_IN_CI = re.compile(r"[:=]\s*[\"']?__SET_IN_CI__[\"']?\s*$")


def is_synthetic(content):
    return bool(SYNTHETIC_RUN_ID.search(content)
                or PLACEHOLDER_SET_IN_CI.search(content))


def load_allowlist(path):
    rules = []
    if not path or not os.path.exists(path):
        return rules
    with open(path, "r", encoding="utf-8") as f:
        for ln in f:
            ln = ln.rstrip("\r\n")
            if not ln.strip() or ln.lstrip().startswith("#"):
                continue
            rule, _sep, reason = ln.partition("# reason:")
            rule = rule.strip()
            if rule:
                rules.append((re.compile(rule), reason.strip() or "(no reason)"))
    return rules


def is_allowed(rules, path, line):
    ctx = "%s:%s" % (path, line)
    for rx, _reason in rules:
        if rx.search(ctx):
            return True
    return False


def git(root, *args):
    r = subprocess.run(["git", "-C", root] + list(args),
                       capture_output=True)
    if r.returncode not in (0,):
        raise RuntimeError("git %s failed: %s" % (" ".join(args),
                                                  r.stderr.decode("utf-8", "ignore")[:400]))
    return r.stdout


def scan_text_lines(text):
    """Yield (line_no, pattern, match_len) for a decoded text block."""
    for name, pat, _hint in PATTERNS:
        rx = re.compile(pat, re.IGNORECASE)
        for i, line in enumerate(text.splitlines(), 1):
            m = rx.search(line)
            if m:
                yield i, name, len(m.group(0))


def mode_head(root, rules, lines):
    files_seen = set()
    hits = 0
    for name, pat, hint in PATTERNS:
        try:
            out = git(root, "grep", "-I", "-n", "-E", "-i", "-e", hint)
        except RuntimeError:
            continue  # no match -> git grep exits 1; RuntimeError raised on >1
        except Exception:
            continue
        rx = re.compile(pat, re.IGNORECASE)
        for ln in out.decode("utf-8", "ignore").splitlines():
            path, _sep, rest = ln.partition(":")
            line_no, _sep, content = rest.partition(":")
            m = rx.search(content)
            if not m:
                continue
            if is_allowed(rules, path, content):
                lines.append("ALLOWED path=%s line=%s pattern=%s (allowlist)" %
                             (path, line_no, name))
                continue
            if is_synthetic(content):
                lines.append("ALLOWED path=%s line=%s pattern=%s (synthetic)" %
                             (path, line_no, name))
                continue
            files_seen.add(path)
            hits += 1
            lines.append("HIT path=%s line=%s pattern=%s match_len=%d" %
                         (path, line_no, name, len(m.group(0))))
    return hits, len(files_seen)


def mode_history(root, rules, lines):
    # map blob -> paths
    blob_paths = {}
    out = git(root, "rev-list", "--objects", "--all").decode("utf-8", "ignore")
    for ln in out.splitlines():
        parts = ln.split(" ", 1)
        if len(parts) == 2:
            blob_paths.setdefault(parts[0], parts[1])

    # every blob in the object DB (includes unreachable objects)
    check = git(root, "cat-file", "--batch-all-objects",
                "--batch-check=%(objecttype) %(objectname) %(objectsize)"
                ).decode("utf-8", "ignore")
    blobs = [ln.split()[1] for ln in check.splitlines()
             if ln.startswith("blob ")]

    p = subprocess.Popen(
        ["git", "-C", root, "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    hits = 0
    objs = set()

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
    try:
        for _ in blobs:
            header = p.stdout.readline().decode("ascii", "ignore").split()
            if len(header) < 3:
                continue
            sha, _typ, size = header[0], header[1], int(header[2])
            data = p.stdout.read(size)
            p.stdout.read(1)  # trailing newline
            text = data.decode("utf-8", "ignore")
            path = blob_paths.get(sha, "<unreachable>")
            for line_no, name, mlen in scan_text_lines(text):
                content_line = text.splitlines()[line_no - 1]
                if is_allowed(rules, path, content_line):
                    lines.append("ALLOWED obj=%s path=%s line=%d pattern=%s (allowlist)" %
                                 (sha[:12], path, line_no, name))
                    continue
                if is_synthetic(content_line):
                    lines.append("ALLOWED obj=%s path=%s line=%d pattern=%s (synthetic)" %
                                 (sha[:12], path, line_no, name))
                    continue
                objs.add(sha[:12])
                hits += 1
                lines.append("HIT obj=%s path=%s line=%d pattern=%s match_len=%d" %
                             (sha[:12], path, line_no, name, mlen))
    finally:
        t.join(timeout=10)
        p.wait()
    return hits, len(objs)


def mode_docs(root, rules, lines):
    docs_root = os.path.join(root, "docs")
    base = docs_root if os.path.isdir(docs_root) else root
    hits = 0
    files_seen = set()
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames
                       if DOCS_EXCLUDE_SUBSTR not in d and d != ".git"]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "rb") as f:
                    head = f.read(8000)
                    if b"\x00" in head:
                        continue  # binary, skip without reading the rest
                    data = f.read()
            except OSError:
                continue
            text = (head + data).decode("utf-8", "ignore")
            data = None
            rel = os.path.relpath(p, root)
            for line_no, name, mlen in scan_text_lines(text):
                content_line = text.splitlines()[line_no - 1]
                if is_allowed(rules, rel, content_line):
                    lines.append("ALLOWED path=%s line=%d pattern=%s (allowlist)" %
                                 (rel, line_no, name))
                    continue
                if is_synthetic(content_line):
                    lines.append("ALLOWED path=%s line=%d pattern=%s (synthetic)" %
                                 (rel, line_no, name))
                    continue
                files_seen.add(rel)
                hits += 1
                lines.append("HIT path=%s line=%d pattern=%s match_len=%d" %
                             (rel, line_no, name, mlen))
    return hits, len(files_seen)


def mode_ipa(root, rules, lines):
    hits = 0
    files_seen = set()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            rel = os.path.relpath(p, root)
            text = data.decode("utf-8", "ignore")
            for line_no, name, mlen in scan_text_lines(text):
                content_line = text.splitlines()[line_no - 1]
                if is_allowed(rules, rel, content_line):
                    lines.append("ALLOWED path=%s line=%d pattern=%s (allowlist)" %
                                 (rel, line_no, name))
                    continue
                if is_synthetic(content_line):
                    lines.append("ALLOWED path=%s line=%d pattern=%s (synthetic)" %
                                 (rel, line_no, name))
                    continue
                files_seen.add(rel)
                hits += 1
                lines.append("HIT path=%s line=%d pattern=%s match_len=%d" %
                             (rel, line_no, name, mlen))
    return hits, len(files_seen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--mode", required=True, choices=["head", "history", "docs", "ipa"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--redact", action="store_true", default=True)
    ap.add_argument("--allowlist", default="scripts/secret_allowlist.txt")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    rules = load_allowlist(os.path.join(root, args.allowlist)
                           if not os.path.isabs(args.allowlist) else args.allowlist)

    lines = []
    lines.append("== REPO SECRET SCAN ==")
    lines.append("mode=%s root=%s redact=on allowlist_rules=%d" %
                 (args.mode, root, len(rules)))

    if args.mode == "head":
        hits, objs = mode_head(root, rules, lines)
    elif args.mode == "history":
        hits, objs = mode_history(root, rules, lines)
    elif args.mode == "docs":
        hits, objs = mode_docs(root, rules, lines)
    else:
        hits, objs = mode_ipa(root, rules, lines)

    lines.append("SUMMARY mode=%s hits=%d files_or_objs=%d" %
                 (args.mode, hits, objs))

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines[-1:]))


if __name__ == "__main__":
    sys.exit(main())
