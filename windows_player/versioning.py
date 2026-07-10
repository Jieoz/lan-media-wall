"""Release version shared by the Windows player and packaged builds."""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Iterable

_VERSION_RE = re.compile(r"^version:\s*([^+\s]+)\+(\d+)\s*$")


def _candidate_pubspecs() -> Iterable[Path]:
    module_dir = Path(__file__).resolve().parent
    yield module_dir.parent / "remote_flutter" / "pubspec.yaml"
    yield module_dir / "pubspec.yaml"
    bundle_dir = getattr(sys, "_MEIPASS", None)
    if bundle_dir:
        yield Path(bundle_dir) / "pubspec.yaml"


def read_release_version(paths: Iterable[Path] | None = None) -> tuple[str, int]:
    for path in paths or _candidate_pubspecs():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            match = _VERSION_RE.match(line)
            if match:
                return match.group(1), int(match.group(2))
    raise RuntimeError("release version not found in bundled pubspec.yaml")


APP_VERSION, APP_VERSION_CODE = read_release_version()
