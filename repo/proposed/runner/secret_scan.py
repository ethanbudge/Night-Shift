#!/usr/bin/env python3
"""Night Shift secret-leak guard. Scans a target directory (a freshly cloned
workspace) for common credential shapes BEFORE the agent edits anything there.

Exit codes:
  0  clean -- no findings
  1  findings -- caller must stop editing this repo/task and flag status:needs-human
  2  error (bad usage)

Prints one line per finding: "<relative path>:<line number>: <pattern name>".
The matched value is NEVER printed, logged, or otherwise surfaced -- only its
location and which pattern tripped. Stdlib only; runs on macOS/Linux/Windows
system python3 (no third-party deps, no network access).
"""

import math
import os
import re
import sys

# Directories never worth descending into: version control internals and the
# usual dependency/build dirs, which are large, third-party, and not the kind
# of place a human would hand-commit a secret.
SKIP_DIRS = {".git", "node_modules", "vendor", "venv", ".venv", "__pycache__", ".tox", "dist", "build"}

# (pattern name, compiled regex). Order matters only for readability; every
# pattern is checked against every line. Keep these specific -- broad patterns
# belong in the generic high-entropy heuristic below, not here.
PATTERNS = [
    ("github-pat-classic", re.compile(r"\bghp_[A-Za-z0-9]{36,}\b")),
    ("github-pat-fine-grained", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}\b")),
    ("github-oauth-token", re.compile(r"\bgho_[A-Za-z0-9]{36,}\b")),
    ("anthropic-api-key", re.compile(r"\bsk-ant-[A-Za-z0-9\-_]{20,}\b")),
    ("openai-api-key", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")),
    ("aws-access-key-id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("pem-private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----")),
]

# Generic fallback: a variable name that merely CONTAINS one of these words
# (so `some_secret`, `db_password`, `apiKey` all count -- a strict word
# boundary would miss the common `prefix_secret` naming style) assigned a
# value that looks like high-entropy random data rather than a normal
# word/identifier/path/URL.
ASSIGNMENT_KEYWORDS = ("apikey", "api_key", "api-key", "secret", "token",
                       "passwd", "password", "pwd", "accesskey", "access_key")
ASSIGNMENT_RE = re.compile(
    r"""([A-Za-z_][A-Za-z0-9_-]{0,60})
        \s*[:=]\s*
        ['"]?([A-Za-z0-9+/_\-]{20,})['"]?""",
    re.VERBOSE,
)


def shannon_entropy(s):
    if not s:
        return 0.0
    counts = {}
    for ch in s:
        counts[ch] = counts.get(ch, 0) + 1
    length = len(s)
    return -sum((c / length) * math.log2(c / length) for c in counts.values())


def is_binary(path, sniff_bytes=8192):
    try:
        with open(path, "rb") as f:
            chunk = f.read(sniff_bytes)
    except OSError:
        return True  # unreadable -- skip rather than guess
    return b"\0" in chunk


def scan_file(path, rel_path):
    findings = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
    except OSError:
        return findings
    for lineno, line in enumerate(lines, start=1):
        for name, pattern in PATTERNS:
            if pattern.search(line):
                findings.append((rel_path, lineno, name))
        m = ASSIGNMENT_RE.search(line)
        if m:
            varname = m.group(1).lower().replace("-", "").replace("_", "")
            value = m.group(2)
            if any(kw.replace("_", "").replace("-", "") in varname for kw in ASSIGNMENT_KEYWORDS) \
                    and shannon_entropy(value) >= 3.5:
                findings.append((rel_path, lineno, "high-entropy-assignment"))
    return findings


def scan_tree(root):
    all_findings = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = os.path.join(dirpath, name)
            if is_binary(path):
                continue
            rel_path = os.path.relpath(path, root)
            all_findings.extend(scan_file(path, rel_path))
    return all_findings


def main():
    if len(sys.argv) != 2:
        print("usage: secret_scan.py <directory>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    if not os.path.isdir(root):
        print(f"error: {root!r} is not a directory", file=sys.stderr)
        return 2

    findings = scan_tree(root)
    if not findings:
        return 0

    for rel_path, lineno, name in sorted(findings):
        print(f"{rel_path}:{lineno}: {name}")
    print(f"\n{len(findings)} potential secret(s) found -- do not edit this repo/task further.",
          file=sys.stderr)
    print("Flag status:needs-human, name the file and pattern above (never the value), "
          "and recommend the owner rotate/remove it.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
