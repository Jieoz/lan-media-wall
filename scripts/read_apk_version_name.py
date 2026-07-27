#!/usr/bin/env python3
"""Read versionName out of an APK without aapt2/apksigner (not available here).

Binary AndroidManifest.xml stores strings as UTF-16LE in its string pool, so the
version literal is found by scanning the decoded pool bytes rather than parsing
the AXML structure. Usage:

    python3 scripts/read_apk_version_name.py <apk> [<apk> ...]
"""
import re
import sys
import zipfile

PATTERN = re.compile(r"^\d+\.\d+\.\d+$")


def version_names(apk_path: str) -> list:
    with zipfile.ZipFile(apk_path) as zf:
        raw = zf.read("AndroidManifest.xml")
    text = raw.decode("utf-16-le", errors="ignore")
    found = []
    for candidate in re.findall(r"[0-9][0-9.]{3,15}", text):
        candidate = candidate.strip(".")
        if PATTERN.match(candidate) and candidate not in found:
            found.append(candidate)
    return found


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: read_apk_version_name.py <apk> [...]")
        return 2
    status = 0
    for apk in sys.argv[1:]:
        try:
            names = version_names(apk)
        except Exception as exc:  # noqa: BLE001 - report and continue
            print("%s -> ERROR %s: %s" % (apk, type(exc).__name__, exc))
            status = 1
            continue
        print("%s -> %s" % (apk, ", ".join(names) if names else "n/a"))
        if not names:
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
