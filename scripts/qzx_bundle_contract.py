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

import re
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
# Detection is by COMMAND POSITION, not substring: a line is split into
# execution segments on the real Batch run operators (``&&``, ``||``, ``|``,
# ``&``); each segment's leading wrappers (``@``, ``call``, ``cmd /c``,
# ``start``) and control heads (``if …``, ``for … do``) are peeled off, and the
# resulting command token's basename is compared against the closed interpreter
# set. A substring scan wrongly passes a bare ``py android_ota\...py`` (no ``-``
# flag) launched behind ``&&`` and wrongly rejects ``copy android_ota\...py
# backup.py``. The name set below is the closed list of Windows Python launchers
# (incl. the windowless ``pythonw``/``pyw`` variants) we refuse to depend on.
# Anchored command-name pattern, rather than a substring scan: it covers the
# standard Windows `py`/`python` launchers, versioned forms (python3.11.exe),
# and windowless variants without treating unrelated names such as
# ``old_python.tmp`` as interpreters.
_INTERPRETER_PATTERN = re.compile(
    r"^(?:pyw?|python(?:w|[23](?:\.\d+)?)?)(?:\.exe)?$", re.IGNORECASE
)

# Batch run operators that start a NEW command in the same line. Longest first
# so `&&`/`||` are not mis-split as two single-char `&`/`|` separators. Batch
# filenames cannot contain these characters, so splitting on them is safe.
_SEGMENT_SPLIT = re.compile(r"&&|\|\||[&|]")

# Control heads whose *argument* is itself a command to run. Once one is seen in
# command position, the remainder of the segment is scanned for an interpreter
# token rather than trusting a fixed position (batch `if`/`for` have variable
# condition arity). `start` launches its target in a new context. Conservative:
# any interpreter token after one of these is treated as an execution.
_CONTROL_HEADS = frozenset({"if", "for", "else", "do", "start"})


def _is_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("::") or stripped.lower().startswith("rem ") or stripped.lower() == "rem"


def _basename(token: str) -> str:
    """Lowercased basename of a token: strip quotes, Batch block parens and any
    path prefix. Batch opens a command block with ``(`` glued to the first
    command (``if … (py x.py)``), so leading/trailing parens are not part of the
    interpreter name."""
    token = token.strip().strip("()").strip('"').strip("'")
    # `%~dp0python.exe` is the common Batch idiom for a sibling executable. It
    # has no literal path separator before the executable name, so normalize the
    # parameter-expansion prefix before taking the basename.
    token = re.sub(r"^%~dp0", "", token, flags=re.IGNORECASE)
    # Basename regardless of \ or / separators (batch uses backslashes).
    return token.replace("/", "\\").rsplit("\\", 1)[-1].lower()


def _is_interpreter_name(token: str) -> bool:
    return bool(_INTERPRETER_PATTERN.fullmatch(_basename(token)))


def _segment_invokes_interpreter(segment: str) -> bool:
    """True if a single execution segment runs a Python interpreter.

    Peels the silent ``@``, ``call``, ``cmd /c`` and ``start`` wrappers, then
    inspects the effective command token. Under a control head (``if``/``for``/
    ``do``/``else``/``start``) the whole remainder is scanned, since the command
    to run appears at a variable offset after the condition.
    """
    tokens = segment.strip().lstrip("@").split()
    while tokens:
        head = _basename(tokens[0])
        if head == "call":
            tokens = tokens[1:]
            continue
        if head in {"cmd", "cmd.exe"}:
            # Skip cmd and its /c /k /s /q … switches, then re-resolve. A
            # common compact form is `/c"command ..."`; retain the quoted
            # remainder as the next command token instead of swallowing it as
            # part of the switch.
            tokens = tokens[1:]
            while tokens and tokens[0].startswith("/"):
                switch = tokens.pop(0)
                quote = switch.find('"')
                if quote >= 0 and switch[quote + 1:]:
                    tokens.insert(0, switch[quote + 1:])
                    break
            continue
        if head in _CONTROL_HEADS:
            # Variable-arity condition: any interpreter token in the remainder
            # is an execution (conservative, fail-closed).
            return any(_is_interpreter_name(t) for t in tokens[1:])
        # Ordinary command: only the command token itself counts.
        return _is_interpreter_name(tokens[0])
    return False


def _line_invokes_interpreter(line: str) -> bool:
    """True if any execution segment of a Batch line runs an interpreter."""
    return any(
        _segment_invokes_interpreter(seg)
        for seg in _SEGMENT_SPLIT.split(line)
    )


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
        if _line_invokes_interpreter(line):
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
