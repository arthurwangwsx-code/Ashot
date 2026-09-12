#!/usr/bin/env python3
"""Fail on likely credentials or local-only files before publishing; never print secret values.

This is a bounded heuristic, not a guarantee. It scans non-ignored working files and all
reachable Git blobs, so removing a credential from the latest tree is not enough.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{30,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{32,}"),
]
PRIVATE_SUFFIXES = {".p12", ".p8", ".pem", ".key", ".mobileprovision", ".provisionprofile"}


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args], cwd=ROOT)


def main() -> int:
    findings: set[str] = set()
    paths = set(git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0"))
    checked = 0
    for raw in sorted(paths):
        if not raw:
            continue
        relative = raw.decode("utf-8", errors="surrogateescape")
        path = ROOT / relative
        if not path.is_file():
            continue
        if path.is_symlink():
            findings.add(f"Symlink requires review: {relative}")
            continue
        if path.suffix.lower() in PRIVATE_SUFFIXES or path.name == ".env" or path.name.startswith(".env."):
            findings.add(f"Private file type: {relative}")
        if "xcuserdata" in path.parts:
            findings.add(f"Local Xcode settings are tracked: {relative}")
        if path.stat().st_size > 10 * 1024 * 1024:
            findings.add(f"Large source file requires review: {relative}")
            continue
        if any(pattern.search(path.read_bytes()) for pattern in PATTERNS):
            findings.add(f"Possible credential: {relative}")
        checked += 1

    # Object names only; credential material is never logged.
    object_ids = sorted({line.split(b" ", 1)[0] for line in git("rev-list", "--objects", "--all").splitlines()})
    # Batch inspection avoids starting an Xcode-provided git process for every object.
    batch = subprocess.run(["git", "cat-file", "--batch"], cwd=ROOT,
                           input=b"\n".join(object_ids) + b"\n", stdout=subprocess.PIPE, check=True).stdout
    cursor = 0
    for _ in object_ids:
        end = batch.index(b"\n", cursor)
        oid, kind, size = batch[cursor:end].split()
        cursor = end + 1
        data = batch[cursor:cursor + int(size)]
        cursor += int(size) + 1
        if kind == b"blob" and any(pattern.search(data) for pattern in PATTERNS):
            findings.add(f"Possible credential in Git history blob: {oid.decode('ascii')}")
    if findings:
        print("Public-source check FAILED:\n" + "\n".join(sorted(findings)), file=sys.stderr)
        return 1
    print(f"Public-source check passed: {checked} working files; {len(object_ids)} history objects checked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
