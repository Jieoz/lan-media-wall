#!/usr/bin/env python3
"""Independently re-verify downloaded release assets against their SHA256SUMS.

Usage: python3 scripts/verify_release_sums.py <dir-with-assets-and-SHA256SUMS>

Exit 0 only when every listed entry is present and its recomputed digest matches.
Used as the delivery gate after `gh release download`: a published release is not
considered verified until the bytes are re-hashed locally.
"""
import hashlib
import os
import re
import sys


def main() -> int:
    directory = sys.argv[1] if len(sys.argv) > 1 else "."
    sums_path = os.path.join(directory, "SHA256SUMS")
    if not os.path.isfile(sums_path):
        print("FATAL: SHA256SUMS not found in %s" % directory)
        return 2

    with open(sums_path, encoding="utf-8") as fh:
        lines = [l.strip() for l in fh.read().splitlines() if l.strip()]

    ok = mismatch = missing = malformed = 0
    for line in lines:
        m = re.match(r"([0-9a-fA-F]{64})\s+\*?(.+)$", line)
        if not m:
            print("MALFORMED %s" % line)
            malformed += 1
            continue
        expected = m.group(1).lower()
        name = m.group(2).strip()
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            print("MISSING  %s" % name)
            missing += 1
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
        got = digest.hexdigest()
        if got == expected:
            print("OK       %s" % name)
            ok += 1
        else:
            print("MISMATCH %s expected=%s got=%s" % (name, expected, got))
            mismatch += 1

    print()
    print(
        "listed=%d ok=%d mismatch=%d missing=%d malformed=%d"
        % (len(lines), ok, mismatch, missing, malformed)
    )
    clean = mismatch == 0 and missing == 0 and malformed == 0 and ok == len(lines)
    print("RESULT=%s" % ("PASS" if clean else "FAIL"))
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
