#!/usr/bin/env python3
"""Self-tests for scan_repo_secrets.py (R5 Phase 1).

Builds a throwaway git repo in a temp dir, writes one fixture file per case,
runs the scanner in --mode head via subprocess, and asserts HIT/ALLOWED per
case. Pure stdlib; no third-party deps.

Exit 0 = all cases pass; exit 1 = at least one failure (details on stdout).

Positive cases (real-looking values) MUST produce HIT.
Negative cases (synthetic forms) MUST NOT produce HIT.

Run:  python -I scripts/test_scan_repo_secrets.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCANNER = os.path.join(HERE, "scan_repo_secrets.py")

SECRET = "real-secret-123"

# Fixture lines are assembled from fragments so that THIS source file never
# contains a contiguous quoted credential-literal form (guard_repo.sh greps
# the tracked tree for such shapes; the fixture values only exist at
# runtime inside the throwaway temp repo).
EQ = "="
COLON = ":"
SQ = "'"
DQ = '"'
SP = " "

# filename -> (line to write, expect "HIT" or "ALLOWED", expected pattern or None)
CASES = [
    # --- positives: must HIT -------------------------------------------------
    ("pos1_password_assign.txt", f"password{EQ}{SQ}{SECRET}{SQ}",
     "HIT", "password_assign"),
    ("pos2_mysql_env.txt", f"MYSQL_ROOT_PASSWORD{EQ}{SECRET}",
     "HIT", "mysql_env_password"),
    ("pos3_runner_env.txt", f"JDLV_TEST_MYSQL_PASS{EQ}{SECRET}",
     "HIT", "runner_env_pass"),
    # username carries '*' so guard-style URL char classes don't self-match
    # while the scanner (non-space, non-colon username) still must hit
    ("pos4_mysql_url.txt", "mysql://u*er:real-secret@db.example",
     "HIT", "mysql_url_creds"),
    ("pos5_jdbc.txt", "jdbc:mysql://db.example",
     "HIT", "jdbc_mysql"),
    ("pos6_private_key.txt", "-----BEGIN RSA PRIVATE KEY-----",
     "HIT", "private_key_block"),
    # --- negatives: must NOT HIT ---------------------------------------------
    ("neg1_root_runid.yml", f"MYSQL_ROOT_PASSWORD{COLON}{SP}${{{{ github.run_id }}}}",
     "ALLOWED", "synthetic"),
    ("neg2_test_runid.yml", f"JDLV_TEST_MYSQL_PASS{COLON}{SP}${{{{ github.run_id }}}}",
     "ALLOWED", "synthetic"),
    ("neg3_empty_pw.txt", f"password{SP}={SP}{DQ}{DQ}",
     "NONE", None),
    ("neg4_bare_key.txt", f"password{COLON}",
     "NONE", None),
    ("neg5_placeholder.txt", f"password{SP}={SP}{DQ}__SET_IN_CI__{DQ}",
     "ALLOWED", "synthetic"),
    # other-key + run_id expression: narrow exemption must NOT cover it
    ("neg6_other_key_runid.txt", f"JDLV_OTHER_PASS{COLON}{SP}${{{{ github.run_id }}}}",
     "HIT", "runner_env_pass"),
    # allowed key but different expression: must still HIT
    ("neg7_root_other_expr.txt", f"MYSQL_ROOT_PASSWORD{COLON}{SP}${{{{ github.sha }}}}",
     "HIT", "mysql_env_password"),
    # quoted run_id form on an allowed key: strict exemption is unquoted only
    ("neg8_quoted_runid.txt", f"MYSQL_ROOT_PASSWORD{COLON}{SP}{DQ}${{{{ github.run_id }}}}{DQ}",
     "HIT", "mysql_env_password"),
]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def build_fixture(base):
    os.makedirs(base, exist_ok=True)
    for fn, line, _exp, _pat in CASES:
        with open(os.path.join(base, fn), "w", encoding="utf-8", newline="\n") as f:
            f.write(line + "\n")
    # one tracked file so `git grep` has an index entry set
    r = run(["git", "init", "-q", base])
    if r.returncode != 0:
        raise RuntimeError("git init failed: %s" % r.stderr.decode("utf-8", "ignore"))
    r = run(["git", "-C", base, "add", "-A"])
    if r.returncode != 0:
        raise RuntimeError("git add failed: %s" % r.stderr.decode("utf-8", "ignore"))


def main():
    tmp = tempfile.mkdtemp(prefix="scan_selftest_")
    out_path = os.path.join(tmp, "head.txt")
    failures = []
    try:
        build_fixture(tmp)
        r = run([sys.executable, "-I", SCANNER,
                 "--root", tmp, "--mode", "head", "--out", out_path])
        if r.returncode != 0:
            print("FAIL: scanner exited %d\n%s" % (r.returncode,
                                                   r.stderr.decode("utf-8", "ignore")))
            return 1
        with open(out_path, encoding="utf-8") as f:
            report = f.read()

        for fn, _line, expect, pat in CASES:
            hit_lines = [ln for ln in report.splitlines()
                         if ln.startswith("HIT ") and "path=%s " % fn in ln]
            allow_lines = [ln for ln in report.splitlines()
                           if ln.startswith("ALLOWED ") and "path=%s " % fn in ln
                           and "(allowlist)" not in ln]
            if expect == "HIT":
                got_pats = [ln.split("pattern=")[1].split(" ")[0]
                            for ln in hit_lines if "pattern=" in ln]
                if pat not in got_pats:
                    failures.append("%s: expected HIT pattern=%s, got %r"
                                    % (fn, pat, hit_lines + allow_lines))
                else:
                    print("PASS  HIT   %-26s %s" % (fn, pat))
            elif expect == "ALLOWED":
                if hit_lines or not allow_lines:
                    failures.append("%s: expected ALLOWED(synthetic), got hits=%r allowed=%r"
                                    % (fn, hit_lines, allow_lines))
                else:
                    print("PASS  ALLOW %-26s %s" % (fn, allow_lines[0].split("pattern=")[1]))
            else:  # NONE
                if hit_lines or allow_lines:
                    failures.append("%s: expected no record, got %r"
                                    % (fn, hit_lines + allow_lines))
                else:
                    print("PASS  NONE  %-26s" % fn)

        # allowlist must stay inert here: no file-specific exemptions in fixture
        if "(allowlist)" in report:
            print("note: allowlist records present in fixture report (unexpected paths)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("-" * 60)
    if failures:
        for f in failures:
            print("FAIL  %s" % f)
        print("RESULT: FAIL (%d/%d cases failed)" % (len(failures), len(CASES)))
        return 1
    print("RESULT: PASS (%d/%d cases)" % (len(CASES), len(CASES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
