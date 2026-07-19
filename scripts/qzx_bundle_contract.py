#!/usr/bin/env python3
"""Fail-closed structural contract for the QZX Update Tools ZIP.

A single pure function, :func:`verify_qzx_bundle`, is the authoritative gate
that proves a field operator can run the offline Android OTA detector on a
stock Windows x64 box with NO Python interpreter installed. It is called both
by the android-build packaging step (before upload) and by release promotion
(before an asset is published), so a malformed bundle fails closed in both
places instead of shipping.

The gate checks:
  * the Chinese double-click launcher ``OTA检测.bat`` exists, begins with a
    UTF-8 BOM, uses CRLF line endings, and never invokes a ``python``/``py``
    interpreter on a non-comment line;
  * a REAL Windows PE executable ships at ``android_ota/android_ota_diag.exe``
    (``MZ`` DOS-header magic);
  * the Python source and both profiles remain for internal/testing use.
"""

from __future__ import annotations

import zipfile
from pathlib import Path


LAUNCHER = "OTA检测.bat"
EXE_MEMBER = "android_ota/android_ota_diag.exe"
REQUIRED_MEMBERS = (
    LAUNCHER,
    EXE_MEMBER,
    "android_ota/android_ota_diag.py",
    "android_ota/profiles/standard-pm.json",
    "android_ota/profiles/qzx-yunos-4.4.json",
)

# A .bat comment is a line whose first non-space token is `rem` or begins `::`.
# Only NON-comment lines are scanned for an interpreter invocation, so a note
# such as "本工具无需安装 Python" (Python mentioned in a comment) does not trip
# the gate.
#
# Detection is by COMMAND TOKEN, not substring: we look at the effective first
# token after Batch's silent `@`, optional `call`, and `cmd /c` wrappers, then
# strip surrounding quotes / a path from a fully-qualified interpreter path.
# A substring scan wrongly passes a bare `py android_ota\...py` (no `-` flag)
# and wrongly rejects `copy android_ota\...py backup.py`. The name set below is
# the closed list of Windows Python launchers we refuse to depend on.
_INTERPRETER_NAMES = frozenset(
    {"py", "py.exe", "python", "python.exe", "python3", "python3.exe"}
)


def _is_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("::") or stripped.lower().startswith("rem ") or stripped.lower() == "rem"


def _command_token(line: str) -> str | None:
    """Return the lowercased basename of a line's command token, or None.

    Resolves the simple Batch wrappers that can conceal a command (``@``,
    ``call``, ``cmd /c``), then strips surrounding quotes and a directory prefix
    from a fully-qualified path (``C:\\Python311\\python.exe`` →
    ``python.exe``). The interpreter name is compared, never matched as a
    substring of an argument.
    """
    tokens = line.strip().lstrip("@").split()
    if not tokens:
        return None
    while tokens and tokens[0].lstrip("@").lower() == "call":
        tokens = tokens[1:]
    if not tokens:
        return None
    first = tokens[0].lstrip("@")
    first_name = first.strip('"').strip("'").replace("/", "\\").rsplit("\\", 1)[-1].lower()
    if first_name in {"cmd", "cmd.exe"}:
        if len(tokens) < 3 or tokens[1].lower() != "/c":
            return first_name
        return _command_token(" ".join(tokens[2:]))
    first = first.strip('"').strip("'")
    # Basename regardless of \ or / separators (batch uses backslashes).
    first = first.replace("/", "\\").rsplit("\\", 1)[-1]
    return first.lower()


def _check_launcher(raw: bytes) -> None:
    if not raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError(f"{LAUNCHER} must begin with a UTF-8 BOM")
    body = raw[3:]
    if b"\r\n" not in body:
        raise ValueError(f"{LAUNCHER} must use CRLF line endings")
    # Every real newline must be CRLF: a bare LF not preceded by CR is illegal.
    if body.replace(b"\r\n", b"").count(b"\n"):
        raise ValueError(f"{LAUNCHER} must use CRLF line endings (found a bare LF)")
    text = body.decode("utf-8")
    for line in text.splitlines():
        if _is_comment(line):
            continue
        if _command_token(line) in _INTERPRETER_NAMES:
            raise ValueError(
                f"{LAUNCHER} must not invoke a python interpreter "
                f"(offending line: {line.strip()!r})"
            )


def verify_qzx_bundle(zip_path: Path) -> list[str]:
    """Validate the QZX Update Tools ZIP, returning its member list.

    Raises ``ValueError`` on the first violated contract.
    """
    zip_path = Path(zip_path)
    if not zip_path.is_file():
        raise ValueError(f"QZX bundle does not exist: {zip_path}")
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        present = set(names)
        for member in REQUIRED_MEMBERS:
            if member not in present:
                raise ValueError(f"QZX bundle missing required member: {member}")
        exe = archive.read(EXE_MEMBER)
        if exe[:2] != b"MZ":
            raise ValueError(
                f"{EXE_MEMBER} is not a Windows PE executable (missing 'MZ' header)"
            )
        _check_launcher(archive.read(LAUNCHER))
    return names


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", type=Path, help="path to LANMediaWall-QZX-Update-Tools.zip")
    args = parser.parse_args()
    members = verify_qzx_bundle(args.zip)
    print(f"QZX_BUNDLE_CONTRACT_PASS {len(members)} members")
    for member in REQUIRED_MEMBERS:
        print(f"  ok {member}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
