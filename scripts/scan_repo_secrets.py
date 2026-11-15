#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Secret scan for JDLV R6 (Phase 1 full rewrite; supersedes R4/R5 scanner).

Modes:
  head     tracked working-tree files (git ls-files)
  history  every blob in the object DB (git cat-file --batch-all-objects),
           path mapping via git rev-list --objects --all (incl. unreachable)
  docs     recursive scan of <root>/docs (fallback: --root itself); scans
           binaries, plists and zip/ipa archives; NO path-class exemptions
  ipa      --root is an .ipa/.zip file or an unpacked app bundle directory

Detection classes: identifiers ending in pass/passwd/password/pwd/passphrase/
secret/token/credential(s)/cred/api_key/access_key/auth_key/private_key with a
literal value; mysql/http(s)/ftp URL credentials; JDBC password params;
IDENTIFIED ... BY quoted literal; private key blocks; plist key/value pairs
(XML+bplist). The matched VALUE is extracted and reduced to sha256[:16]; raw
values are NEVER printed. Output fields: path / obj / enc / line / off /
pattern / len / hash (+ plist keypath, + reason for ALLOWED).

Exemptions are STRUCTURAL ONLY -- never path-based:
  - empty value; GitHub Actions expression syntax; shell/env refs (dollar
    variable, command substitution, percent vars); runtime generated
    (openssl rand); runtime env refs (ProcessInfo/os.environ); placeholder
    tokens (__SET_IN_CI__ / REDACTED / CHANGE_ME / PLACEHOLDER);
  - inline annotation marker "secret-scan:allow" on the same line;
  - scripts/secret_allowlist.txt: structural reference regexes matched against
    the LINE CONTENT only (a rule cannot exempt by path alone).
Known leaked values (optional --known-hashes file, sha256[:16] hex per line)
turn the affected HIT lines into KNOWN-LEAK (still counted as hits).

Exit code is 0 whenever the scan completed; gates grep the report
('^HIT' / '^KNOWN-LEAK' / '^ALLOWED') rather than rely on exit codes.
"""

import argparse
import hashlib
import io
import os
import plistlib
import re
import subprocess
import sys
import zipfile

# assembled at runtime so this source file never contains the raw form
GH_EXPR_PREFIX = "$" + "{" + "{"

# --------------------------------------------------------------------------
# detection patterns
# --------------------------------------------------------------------------

SENSITIVE_SUFFIX_RE = re.compile(
    r"(?:password|passphrase|passwd|credentials|credential|pass|pwd|"
    r"secret|token|cred|api_?key|access_?key|auth_?key|private_?key)$"
)

NEGATIVE_IDENTS = {
    "bypass", "passthrough", "passport", "compass", "overpass", "surpass",
}

QUOTED = r"(?:\"(?P<dq>[^\"\r\n]{0,200})\"|'(?P<sq>[^'\r\n]{0,200})')"

ASSIGN_QUOTED_RE = re.compile(
    r"(?P<id>[A-Za-z_][A-Za-z0-9_\-]{0,80})[\"']?\s*[:=]{1,2}\s*" + QUOTED)

ASSIGN_BARE_RE = re.compile(
    r"(?P<id>[A-Za-z_][A-Za-z0-9_\-]{0,80})[\"']?\s*[:=]{1,2}\s*"
    r"(?P<bare>[^\s'\"#]{1,200})")

URL_CREDS_RE = re.compile(
    r"\b(?:mysql|jdbc:mysql|https?|ftps?)://"
    r"(?P<user>[^\s/:@'\"<>]{1,64}):(?P<pw>[^\s/@'\"<>]{1,200})@")

JDBC_PARAM_RE = re.compile(
    r"[?&](?:password|passwd|pwd)=([^\s&'\"#<>]{1,200})", re.IGNORECASE)

IDENTIFIED_BY_RE = re.compile(
    r"IDENTIFIED\s+(?:WITH\s+[\w.]+\s+)?BY\s+"
    r"(?:'(?P<sq>[^']{1,200})'|\"(?P<dq>[^\"]{1,200})\")", re.IGNORECASE)

PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----")

PLACEHOLDER_VALUES = {
    "__SET_IN_CI__", "__REDACTED__", "REDACTED", "CHANGE_ME", "CHANGEME",
    "PLACEHOLDER", "placeholder",
}

ANNOTATION_MARKER = "secret-scan:allow"

# bare RHS values containing these are code expressions, not literals
BARE_DISCARD_CHARS = set("(){}[].,:;<>=+*!?|&/~^")

# bare values equal to these (case-insensitive) are types/switch words, not
# credential literals
BARE_VALUE_KEYWORDS = {
    "string", "int", "int64", "bool", "double", "float", "true", "false",
    "yes", "no", "on", "off", "nil", "null", "none", "void",
}

# unquoted bare RHS is a config-file idiom; in compiled-source languages a
# bare RHS can never be a string literal, so the bare pattern is restricted
# to config-ish extensions (quoted-literal detection applies everywhere)
BARE_ALLOWED_EXT = {
    ".yml", ".yaml", ".sh", ".env", ".properties", ".ini", ".cfg", ".conf",
    ".txt", ".md", ".rst", ".bat", ".cmd", ".ps1", ".sql", ".py", ".toml",
    "",
}


def bare_allowed_for(rel):
    tail = rel.split("!")[-1]
    ext = os.path.splitext(tail)[1].lower()
    return ext in BARE_ALLOWED_EXT

MAX_ZIP_DEPTH = 3
MAX_ZIP_BYTES = 256 * 1024 * 1024
MAX_PLIST_BYTES = 64 * 1024 * 1024


def ident_is_sensitive(ident):
    low = ident.strip("_-").lower()
    if not low or low in NEGATIVE_IDENTS:
        return False
    return bool(SENSITIVE_SUFFIX_RE.search(low))


def classify_value(v):
    """Return (is_structural, tag) for an extracted raw value."""
    if v is None:
        return True, "structural-empty"
    t = v.strip()
    if t == "":
        return True, "structural-empty"
    if t.startswith(GH_EXPR_PREFIX):
        return True, "structural-github-expression"
    if t.startswith("$"):
        return True, "structural-shell-env-ref"
    if len(t) >= 3 and t.startswith("%") and t.endswith("%"):
        return True, "structural-shell-env-ref"
    if "openssl rand" in t:
        return True, "structural-runtime-generated"
    if "ProcessInfo" in t or "os.environ" in t or "environment[" in t:
        return True, "structural-runtime-env-ref"
    if t in PLACEHOLDER_VALUES:
        return True, "structural-placeholder"
    return False, ""


def bare_is_literal(v):
    """A bare (unquoted) RHS is only reported when it looks like a plain
    literal, not like source code (function call, dotted path...)."""
    if v.lower() in BARE_VALUE_KEYWORDS:
        return False
    return not any(c in BARE_DISCARD_CHARS for c in v)


def value_hash(v):
    if v is None:
        v = ""
    return hashlib.sha256(v.encode("utf-8", "surrogatepass")).hexdigest()[:16]


def scan_line(line, allow_bare=True):
    """Return [(pattern, value, col)] for one line of decoded text."""
    found = []
    m = PRIVATE_KEY_RE.search(line)
    if m:
        found.append(("private_key_block", m.group(0), m.start()))
    m = URL_CREDS_RE.search(line)
    if m:
        found.append(("url_credentials", m.group("pw"), m.start()))
    m = JDBC_PARAM_RE.search(line)
    if m:
        found.append(("jdbc_url_password", m.group(1), m.start()))
    m = IDENTIFIED_BY_RE.search(line)
    if m:
        v = m.group("sq") if m.group("sq") is not None else m.group("dq")
        found.append(("sql_identified_by", v, m.start()))
    has_url = any(p in ("url_credentials", "jdbc_url_password")
                  for p, _v, _c in found)
    if not has_url:
        for mm in ASSIGN_QUOTED_RE.finditer(line):
            if ident_is_sensitive(mm.group("id")):
                v = mm.group("dq") if mm.group("dq") is not None else mm.group("sq")
                found.append(("assign_quoted", v, mm.start()))
        for mm in ASSIGN_BARE_RE.finditer(line):
            if allow_bare and ident_is_sensitive(mm.group("id")):
                v = mm.group("bare")
                if bare_is_literal(v):
                    found.append(("assign_bare", v, mm.start()))
    return found


# --------------------------------------------------------------------------
# byte-level helpers (prefilter, plists, zip containers)
# --------------------------------------------------------------------------

_PREFILTER_WORDS = ["pass", "passwd", "password", "pwd", "secret", "token",
                    "credential", "cred", "mysql", "jdbc", "identified",
                    "private key", "http", "ftp", "://"]

PREFILTER_RE = re.compile(
    b"(?i)(" + b"|".join(re.escape(w.encode("ascii")) for w in _PREFILTER_WORDS) + b")")


def _u16le(s):
    return b"".join(bytes([c]) + b"\x00" for c in s.encode("ascii"))


def _u16be(s):
    return b"".join(b"\x00" + bytes([c]) for c in s.encode("ascii"))


def _u16_alt(enc_fn):
    parts = []
    for w in _PREFILTER_WORDS:
        if w == "://":
            continue
        parts.append(re.escape(enc_fn(w)))
    return re.compile(b"(?i)(?:" + b"|".join(parts) + b")")


PREFILTER_U16LE_RE = _u16_alt(_u16le)
PREFILTER_U16BE_RE = _u16_alt(_u16be)


def bytes_look_relevant(data):
    if PREFILTER_RE.search(data):
        return True
    if len(data) >= 8:
        if PREFILTER_U16LE_RE.search(data):
            return True
        if PREFILTER_U16BE_RE.search(data):
            return True
    return False


def _walk_plist(obj, path, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            kp = path + "/" + str(k)
            if (isinstance(v, str) and ident_is_sensitive(str(k))
                    and not classify_value(v)[0] and v.strip() != ""):
                out.append(("plist_cred", v, kp))
            else:
                _walk_plist(v, kp, out)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _walk_plist(v, path + "/%d" % i, out)


def scan_plist_data(data, rel, rules, known):
    recs = []
    if len(data) > MAX_PLIST_BYTES:
        return recs
    if not (data[:8] == b"bplist00" or data[:6] == b"<?xml "):
        return recs
    try:
        pl = plistlib.loads(data)
    except Exception:
        return recs
    found = []
    _walk_plist(pl, "", found)
    for pat, v, kp in found:
        recs.append(make_rec(rel, "plist", 0, 0, pat, v, rules, known,
                             plist=kp))
    return recs


def scan_zip_data(data, rel, depth, rules, known, notes):
    recs = []
    if depth > MAX_ZIP_DEPTH or len(data) > MAX_ZIP_BYTES:
        return recs
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except Exception:
        return recs
    try:
        for info in zf.infolist():
            if info.file_size > MAX_ZIP_BYTES:
                continue
            mrel = rel + "!" + info.filename
            try:
                mdata = zf.read(info)
            except Exception:
                continue
            recs += scan_container(mdata, mrel, depth + 1, rules, known, notes)
    finally:
        try:
            zf.close()
        except Exception:
            pass
    return recs


def make_rec(rel, enc, line_no, off, pat, val, rules, known, obj=None,
             plist=None, line_text=""):
    h = value_hash(val)
    label = "HIT"
    reason = ""
    if ANNOTATION_MARKER in line_text:
        label, reason = "ALLOWED", "annotation"
    else:
        hit_rule = False
        for rx, _r in rules:
            if rx.search(line_text):
                hit_rule = True
                label = "ALLOWED"
                reason = "allowlist"
                break
        if not hit_rule:
            structural, tag = classify_value(val)
            if structural:
                label, reason = "ALLOWED", tag
        if label == "HIT" and h in known:
            label, reason = "KNOWN-LEAK", "known-hash"
    rec = {
        "label": label, "path": rel, "enc": enc, "line": line_no,
        "off": off, "pattern": pat, "len": (len(val) if val is not None else 0),
        "hash": h, "obj": obj, "plist": plist,
    }
    if reason:
        rec["reason"] = reason
    return rec


def scan_text(text, rel, enc, rules, known, bpc=1, shift=0, obj=None):
    recs = []
    line_start = 0
    allow_bare = bare_allowed_for(rel)
    for i, line in enumerate(text.split("\n"), 1):
        for pat, val, col in scan_line(line, allow_bare=allow_bare):
            off = shift + (line_start + col) * bpc
            recs.append(make_rec(rel, enc, i, off, pat, val, rules, known,
                                 obj=obj, line_text=line))
        line_start += len(line) + 1
    return recs


def scan_bytes_full(data, rel, rules, known, obj=None):
    recs = []
    text = data.decode("utf-8", "ignore")
    recs += scan_text(text, rel, "utf-8", rules, known, obj=obj)
    for enc in ("utf-16-le", "utf-16-be"):
        for shift in (0, 1):
            chunk = data[shift:]
            if len(chunk) < 2:
                continue
            t16 = chunk.decode(enc, "ignore")
            if not t16:
                continue
            tag = enc + ("-shift1" if shift else "")
            recs += scan_text(t16, rel, tag, rules, known, bpc=2,
                              shift=shift, obj=obj)
    recs += scan_plist_data(data, rel, rules, known)
    return recs


def scan_container(data, rel, depth=0, rules=(), known=frozenset(), notes=None):
    """Scan one container (file bytes / blob / zip member)."""
    if data[:4] in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08") and depth <= MAX_ZIP_DEPTH:
        return scan_zip_data(data, rel, depth, rules, known, notes)
    if not bytes_look_relevant(data):
        return []
    return scan_bytes_full(data, rel, rules, known)


# --------------------------------------------------------------------------
# allowlist (structural reference regexes, matched against line content only)
# --------------------------------------------------------------------------

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


def load_known_hashes(path):
    out = set()
    if not path or not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for ln in f:
            ln = ln.strip().lower()
            if len(ln) >= 16:
                out.add(ln[:16])
    return out


# --------------------------------------------------------------------------
# modes
# --------------------------------------------------------------------------

def _fmt(rec):
    parts = [rec["label"]]
    if rec.get("obj"):
        parts.append("obj=%s" % rec["obj"])
    parts.append("path=%s" % rec["path"])
    parts.append("enc=%s" % rec["enc"])
    parts.append("line=%d" % rec["line"])
    parts.append("off=%d" % rec["off"])
    if rec.get("plist"):
        parts.append("plist=%s" % rec["plist"])
    parts.append("pattern=%s" % rec["pattern"])
    parts.append("len=%d" % rec["len"])
    parts.append("hash=%s" % rec["hash"])
    if rec.get("reason"):
        parts.append("reason=%s" % rec["reason"])
    return " ".join(parts)


def _count(recs, seen, hits_box, allowed_box):
    for r in recs:
        seen.add(r["path"])
        if r["label"] in ("HIT", "KNOWN-LEAK"):
            hits_box[0] += 1
        else:
            allowed_box[0] += 1


def git(root, *args):
    r = subprocess.run(["git", "-C", root] + list(args), capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args),
                                                  r.stderr.decode("utf-8", "ignore")[:400]))
    return r.stdout


def mode_head(root, rules, known, lines):
    files = [f for f in git(root, "ls-files", "-z").decode("utf-8", "ignore").split("\x00") if f]
    hits_box = [0]
    allowed_box = [0]
    seen = set()
    for rel in files:
        p = os.path.join(root, *rel.split("/"))
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        recs = scan_container(data, rel, 0, rules, known)
        for r in recs:
            lines.append(_fmt(r))
        _count(recs, seen, hits_box, allowed_box)
    return hits_box[0], allowed_box[0], len(seen)


def mode_history(root, rules, known, lines):
    blob_paths = {}
    out = git(root, "rev-list", "--objects", "--all").decode("utf-8", "ignore")
    for ln in out.splitlines():
        parts = ln.split(" ", 1)
        if len(parts) == 2:
            blob_paths.setdefault(parts[0], parts[1])
    check = git(root, "cat-file", "--batch-all-objects",
                "--batch-check=%(objecttype) %(objectname) %(objectsize)"
                ).decode("utf-8", "ignore")
    blobs = [ln.split()[1] for ln in check.splitlines() if ln.startswith("blob ")]
    p = subprocess.Popen(
        ["git", "-C", root, "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE)

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
    hits_box = [0]
    allowed_box = [0]
    seen = set()
    try:
        for _ in blobs:
            header = p.stdout.readline().decode("ascii", "ignore").split()
            if len(header) < 3:
                continue
            sha, _typ, size = header[0], header[1], int(header[2])
            data = p.stdout.read(size)
            p.stdout.read(1)
            rel = blob_paths.get(sha, "<unreachable>")
            recs = scan_container(data, rel, 0, rules, known)
            for r in recs:
                r["obj"] = sha[:12]
                lines.append(_fmt(r))
            _count(recs, seen, hits_box, allowed_box)
    finally:
        t.join(timeout=10)
        p.wait()
    return hits_box[0], allowed_box[0], len(seen)


def mode_docs(root, rules, known, lines):
    docs_root = os.path.join(root, "docs")
    base = docs_root if os.path.isdir(docs_root) else root
    hits_box = [0]
    allowed_box = [0]
    seen = set()
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            recs = scan_container(data, rel, 0, rules, known)
            for r in recs:
                lines.append(_fmt(r))
            _count(recs, seen, hits_box, allowed_box)
    return hits_box[0], allowed_box[0], len(seen)


def mode_ipa(root, rules, known, lines):
    hits_box = [0]
    allowed_box = [0]
    seen = set()
    if os.path.isfile(root):
        with open(root, "rb") as f:
            data = f.read()
        recs = scan_container(data, os.path.basename(root), 0, rules, known)
        for r in recs:
            lines.append(_fmt(r))
        _count(recs, seen, hits_box, allowed_box)
    else:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for fn in filenames:
                p = os.path.join(dirpath, fn)
                try:
                    with open(p, "rb") as f:
                        data = f.read()
                except OSError:
                    continue
                rel = os.path.relpath(p, root).replace(os.sep, "/")
                recs = scan_container(data, rel, 0, rules, known)
                for r in recs:
                    lines.append(_fmt(r))
                _count(recs, seen, hits_box, allowed_box)
    return hits_box[0], allowed_box[0], len(seen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--mode", required=True, choices=["head", "history", "docs", "ipa"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--redact", action="store_true", default=True)
    ap.add_argument("--allowlist", default="scripts/secret_allowlist.txt")
    ap.add_argument("--known-hashes", default=None,
                    help="optional file with sha256[:16] hex of known leaked values")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    alw = args.allowlist
    if alw and not os.path.isabs(alw):
        cand = os.path.join(root, alw)
        alw = cand if os.path.exists(cand) else alw
    rules = load_allowlist(alw)
    known = load_known_hashes(args.known_hashes)

    lines = []
    lines.append("== REPO SECRET SCAN (R6) ==")
    lines.append("mode=%s root=%s redact=on allowlist_rules=%d known_hashes=%d"
                 % (args.mode, root, len(rules), len(known)))

    if args.mode == "head":
        hits, allowed, seen = mode_head(root, rules, known, lines)
    elif args.mode == "history":
        hits, allowed, seen = mode_history(root, rules, known, lines)
    elif args.mode == "docs":
        hits, allowed, seen = mode_docs(root, rules, known, lines)
    else:
        hits, allowed, seen = mode_ipa(root, rules, known, lines)

    lines.append("SUMMARY mode=%s hits=%d allowed=%d files_or_objs=%d"
                 % (args.mode, hits, allowed, seen))
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines[-1:]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
