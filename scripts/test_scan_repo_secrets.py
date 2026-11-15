#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Self-tests for scan_repo_secrets.py (R6 Phase 1 rewrite).

Positive fixtures MUST produce HIT; negative (structural) fixtures MUST NOT
produce HIT. Fixture shapes are assembled at runtime so this tracked source
never contains a scannable credential-literal shape itself, and raw values
are never printed (reports carry path/line/len/hash only).

Run:  python -I scripts/test_scan_repo_secrets.py
Exit 0 = all cases pass; exit 1 = at least one failure (details on stdout).
"""

import importlib.util
import io
import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCANNER_PATH = os.path.join(HERE, "scan_repo_secrets.py")

spec = importlib.util.spec_from_file_location("scan_repo_secrets", SCANNER_PATH)
SC = importlib.util.module_from_spec(spec)
spec.loader.exec_module(SC)

EQ = "="
COLON = ":"
SP = " "
DQ = '"'
SQ = "'"

VAL_A = "Sup3rS3cretV4l"
VAL_B = "tok3nS3cret99"
PW_URL = "P4ssw0rdX9"
PLIST_PW = "plistS3cret1"
ZIP_PW = "zippedS3cret"
BIN_PW = "hunter2bin"
YAML_PW = "root"
SQL_PW = "sqlpass99"
JDBC_PW = "jdbcpass7"
FIX_PW = "fx-123456"

GH = SC.GH_EXPR_PREFIX
PK = "-----" + "BEGIN" + " RSA" + " PRIVATE" + " KEY" + "-----"
URL = "mysql://" + "user1" + COLON + PW_URL + "@" + "db.example"

XML_PLIST = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<plist version="1.0"><dict>'
    "<key>Root" + "Password</key>"
    "<string>" + PLIST_PW + "</string>"
    "</dict></plist>"
)

_BIN_PLIST = plistlib.dumps({"Api" + "Token": VAL_B}, fmt=plistlib.FMT_BINARY)

_BUF = io.BytesIO()
with zipfile.ZipFile(_BUF, "w") as _z:
    _z.writestr("config/settings.txt",
                "dbpass" + SP + EQ + SP + DQ + ZIP_PW + DQ + "\n")
ZIP_BYTES = _BUF.getvalue()

# (case name, rel path, bytes, expectation)
# expectation: "HIT:<pattern>" / "NONE"
CASES = [
    # ---- positives: must HIT ----
    ("pos_swift_default", "Fixture1.swift",
     ("s.remotePass" + SP + EQ + SP + DQ + VAL_A + DQ).encode("utf-8"),
     "HIT:assign_quoted"),
    ("pos_url_creds", "dbconf.txt",
     ("db" + EQ + URL).encode("utf-8"),
     "HIT:url_credentials"),
    ("pos_utf16le", "enc16.txt",
     ("token" + SP + EQ + SP + DQ + VAL_B + DQ).encode("utf-16-le"),
     "HIT:assign_quoted"),
    ("pos_utf16be", "enc16be.txt",
     ("passwd" + SP + EQ + SP + DQ + VAL_B + DQ).encode("utf-16-be"),
     "HIT:assign_quoted"),
    ("pos_xml_plist", "Info.plist", XML_PLIST.encode("utf-8"),
     "HIT:plist_cred"),
    ("pos_bplist", "Root.plist", _BIN_PLIST, "HIT:plist_cred"),
    ("pos_macho_str", "PayloadBin",
     b"\xcf\xfa\xed\xfe\x00\x01\x02\x03junk\x00"
     + ("password" + EQ + DQ + BIN_PW + DQ).encode("utf-8") + b"\x00\x00",
     "HIT:assign_quoted"),
    ("pos_zip_member", "archive.ipa", ZIP_BYTES, "HIT:assign_quoted"),
    ("pos_yaml_bare", "ci.yml",
     ("MYSQL_ROOT_PASSWORD" + COLON + SP + YAML_PW + "\n").encode("utf-8"),
     "HIT:assign_bare"),
    ("pos_sql_identified", "seed.sql",
     ("CREATE USER 'u'@'%' IDENTIFIED" + " BY " + SQ + SQL_PW + SQ).encode("utf-8"),
     "HIT:sql_identified_by"),
    ("pos_jdbc_param", "conf.properties",
     ("jdbc:mysql://h/db?user=u&password" + EQ + JDBC_PW).encode("utf-8"),
     "HIT:jdbc_url_password"),
    ("pos_private_key", "leaked.txt",
     (PK + "\nMIIEowIBAAKCAQ\n").encode("utf-8"),
     "HIT:private_key_block"),
    # ---- negatives: must NOT HIT ----
    ("neg_empty_swift", "Fixture2.swift",
     ("s.remotePass" + SP + EQ + SP + DQ + DQ).encode("utf-8"), "NONE"),
    ("neg_runtime_env", "Fixture3.swift",
     ("s.remotePass" + SP + EQ + SP +
      "ProcessInfo.processInfo.environment[" + DQ + "X" + DQ + "]").encode("utf-8"),
     "NONE"),
    ("neg_github_expr", "ci2.yml",
     ("MYSQL_ROOT_PASSWORD" + COLON + SP + GH + " github.run_id " + "}}").encode("utf-8"),
     "NONE"),
    ("neg_openssl", "ci3.yml",
     ("JDLV_FIXTURE_PASS" + COLON + SP + "$(" + "openssl rand -hex 16)").encode("utf-8"),
     "NONE"),
    ("neg_annotation", "Fixture4.swift",
     ("fixturePass" + SP + EQ + SP + DQ + FIX_PW + DQ + SP + "// "
      + SC.ANNOTATION_MARKER + " structural test fixture").encode("utf-8"),
     "NONE"),
    ("neg_bypass_ident", "cfg.txt",
     ("bypass" + SP + EQ + SP + DQ + "cfg-value" + DQ).encode("utf-8"), "NONE"),
    ("neg_swift_type", "Fixture5.swift",
     ("public var pass" + COLON + SP + "String").encode("utf-8"), "NONE"),
    ("neg_swift_rhs_ident", "Fixture6.swift",
     ("$0.localPass" + SP + EQ + SP + "v").encode("utf-8"), "NONE"),
    ("neg_key_only", "keys.txt", b"remote_pass\n", "NONE"),
    ("neg_utf16be_empty", "enc16be2.txt",
     ("password" + SP + EQ + SP + DQ + DQ).encode("utf-16-be"), "NONE"),
    ("neg_yaml_keyword", "ci4.yml",
     ("PASSWORD" + COLON + SP + "String").encode("utf-8"), "NONE"),
    ("neg_placeholder", "ci5.yml",
     ("MYSQL_ROOT_PASSWORD" + COLON + SP + "__SET_IN_CI__").encode("utf-8"),
     "NONE"),
]


def run_case(name, rel, data, expect):
    recs = SC.scan_container(data, rel, 0, [], frozenset())
    hits = [r for r in recs if r["label"] in ("HIT", "KNOWN-LEAK")]
    pats = sorted(set(r["pattern"] for r in hits))
    if expect == "NONE":
        if hits:
            return "FAIL: expected no HIT, got %s" % pats
        return None
    want_pat = expect.split(":", 1)[1]
    if not hits:
        return "FAIL: expected HIT %s, got none (recs=%d)" % (want_pat, len(recs))
    if want_pat not in pats:
        return "FAIL: expected pattern %s, got %s" % (want_pat, pats)
    for r in hits:
        if len(r["hash"]) != 16:
            return "FAIL: bad hash field"
        if r["len"] <= 0 and r["pattern"] != "plist_cred":
            return "FAIL: bad len field"
    return None


def check_redaction(report_text):
    leaked = [v for v in (VAL_A, VAL_B, PW_URL, PLIST_PW, ZIP_PW, BIN_PW,
                          SQL_PW, JDBC_PW, FIX_PW) if v in report_text]
    return leaked


def main():
    failures = []

    # Part A: unit cases through scan_container
    for name, rel, data, expect in CASES:
        err = run_case(name, rel, data, expect)
        if err:
            failures.append("%s: %s" % (name, err))
        else:
            print("PASS %s (%s)" % (name, expect))

    # Part B: end-to-end head mode in a throwaway git repo
    tmp = tempfile.mkdtemp(prefix="scan_selftest_r6_")
    out_path = os.path.join(tmp, "head.txt")
    try:
        os.makedirs(os.path.join(tmp, "sub"), exist_ok=True)
        fixtures = [
            ("app_swift.swift",
             "s.remotePass" + SP + EQ + SP + DQ + VAL_A + DQ + "\n"),
            ("pipeline.yml",
             "MYSQL_ROOT_PASSWORD" + COLON + SP + YAML_PW + "\n"),
            ("clean_swift.swift",
             "s.remotePass" + SP + EQ + SP + DQ + DQ + "\n"),
        ]
        for fn, line in fixtures:
            with open(os.path.join(tmp, fn), "w", encoding="utf-8",
                      newline="\n") as f:
                f.write(line)
        for args in (["init", "-q"], ["add", "-A"]):
            r = subprocess.run(["git", "-C", tmp] + args, capture_output=True)
            if r.returncode != 0:
                failures.append("git %s failed: %s" % (args[0], r.stderr.decode("utf-8", "ignore")))
        r = subprocess.run([sys.executable, "-I", SCANNER_PATH,
                            "--root", tmp, "--mode", "head",
                            "--out", out_path], capture_output=True)
        if r.returncode != 0:
            failures.append("scanner exited %d: %s" % (
                r.returncode, r.stderr.decode("utf-8", "ignore")[:400]))
        else:
            with open(out_path, encoding="utf-8") as f:
                report = f.read()
            hit_paths = set()
            for ln in report.splitlines():
                if ln.startswith("HIT ") or ln.startswith("KNOWN-LEAK "):
                    for tok in ln.split(" "):
                        if tok.startswith("path="):
                            hit_paths.add(tok[5:])
            if "app_swift.swift" not in hit_paths:
                failures.append("head-mode: missing HIT for app_swift.swift")
            if "pipeline.yml" not in hit_paths:
                failures.append("head-mode: missing HIT for pipeline.yml")
            if "clean_swift.swift" in hit_paths:
                failures.append("head-mode: unexpected HIT for clean_swift.swift")
            if not any(ln.startswith("SUMMARY mode=head ") for ln in report.splitlines()):
                failures.append("head-mode: SUMMARY line missing")
            leaked = check_redaction(report)
            if leaked:
                failures.append("head-mode: report leaked %d raw value(s)" % len(leaked))
        if not failures:
            print("PASS head-mode end-to-end (hits redacted, summary present)")
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    # Part C: allowlist mechanism (structural rule on line content)
    alw_path = os.path.join(tempfile.mkdtemp(prefix="scan_alw_r6_"), "alw.txt")
    with open(alw_path, "w", encoding="utf-8") as f:
        f.write("FIXTURE_R6_VAL_B  # reason: synthetic variable name, not a value\n")
    rules = SC.load_allowlist(alw_path)
    rec = SC.make_rec("x.txt", "utf-8", 1, 0, "assign_quoted", "whatever",
                      rules, frozenset(),
                      line_text="FIXTURE_R6_VAL_B" + SP + EQ + SP + DQ + "whatever" + DQ)
    if rec["label"] != "ALLOWED":
        failures.append("allowlist: expected ALLOWED, got %s" % rec["label"])
    else:
        print("PASS allowlist structural rule")

    if failures:
        print("FAILURES: %d" % len(failures))
        for f in failures:
            print("  " + f)
        return 1
    print("ALL SELF-TESTS PASS (%d cases)" % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
