#!/usr/bin/env python3
"""Fail-closed contract for the Windows no-Python OTA detector bundle.

verify_qzx_bundle() is the single pure gate used by both the android-build
packaging step and release promotion. It proves the QZX Update Tools ZIP can be
run by a field operator on a stock Windows x64 box with NO interpreter:

  * the Chinese double-click launcher is present, UTF-8 BOM + CRLF, and never
    invokes a python/py interpreter;
  * a REAL Windows PE executable (``MZ`` magic) ships alongside it;
  * the Python source and both profiles remain for internal/testing use.

Malformed or missing members must raise, never pass silently.
"""
import importlib.util
import io
import zipfile
from pathlib import Path

import pytest


SCRIPT = Path(__file__).resolve().parents[1] / "qzx_bundle_contract.py"
SPEC = importlib.util.spec_from_file_location("qzx_bundle_contract", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

LAUNCHER = "OTA检测.bat"
GOOD_BAT = "﻿@echo off\r\nchcp 65001\r\nandroid_ota\\android_ota_diag.exe --human\r\npause\r\n".encode("utf-8")
GOOD_EXE = b"MZ\x90\x00" + b"\x00" * 128


def _bundle(members: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in members.items():
            archive.writestr(name, data)
    return buffer.getvalue()


def _complete() -> dict[str, bytes]:
    return {
        LAUNCHER: GOOD_BAT,
        "android_ota/android_ota_diag.exe": GOOD_EXE,
        "android_ota/android_ota_diag.py": b"# python source\n",
        "android_ota/profiles/standard-pm.json": b"{}\n",
        "android_ota/profiles/qzx-yunos-4.4.json": b"{}\n",
    }


def test_complete_bundle_passes(tmp_path: Path) -> None:
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(_complete()))
    # Must not raise and must report every mandatory member.
    members = MODULE.verify_qzx_bundle(path)
    assert LAUNCHER in members
    assert "android_ota/android_ota_diag.exe" in members


def test_missing_launcher_fails(tmp_path: Path) -> None:
    members = _complete()
    del members[LAUNCHER]
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="OTA检测.bat"):
        MODULE.verify_qzx_bundle(path)


def test_missing_exe_fails(tmp_path: Path) -> None:
    members = _complete()
    del members["android_ota/android_ota_diag.exe"]
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="android_ota_diag.exe"):
        MODULE.verify_qzx_bundle(path)


def test_exe_without_pe_header_fails(tmp_path: Path) -> None:
    members = _complete()
    members["android_ota/android_ota_diag.exe"] = b"#!/bin/sh\n"  # not a PE
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="MZ"):
        MODULE.verify_qzx_bundle(path)


def test_launcher_without_bom_fails(tmp_path: Path) -> None:
    members = _complete()
    members[LAUNCHER] = GOOD_BAT[3:]  # strip the UTF-8 BOM
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="BOM"):
        MODULE.verify_qzx_bundle(path)


def test_launcher_without_crlf_fails(tmp_path: Path) -> None:
    members = _complete()
    members[LAUNCHER] = GOOD_BAT.replace(b"\r\n", b"\n")  # LF only
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="CRLF"):
        MODULE.verify_qzx_bundle(path)


def test_launcher_invoking_python_fails(tmp_path: Path) -> None:
    members = _complete()
    members[LAUNCHER] = (
        "﻿@echo off\r\npython android_ota\\android_ota_diag.py --human\r\npause\r\n"
    ).encode("utf-8")
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="interpreter"):
        MODULE.verify_qzx_bundle(path)


@pytest.mark.parametrize(
    "command",
    [
        "py android_ota\\android_ota_diag.py analyze bundle.zip",
        "py.exe android_ota\\android_ota_diag.py",
        "python android_ota\\android_ota_diag.py",
        "python.exe android_ota\\android_ota_diag.py",
        "python3 android_ota\\android_ota_diag.py",
        "python3.exe android_ota\\android_ota_diag.py",
        "call py android_ota\\android_ota_diag.py",
        "call python.exe android_ota\\android_ota_diag.py",
        "@python android_ota\\android_ota_diag.py",
        "@call py android_ota\\android_ota_diag.py",
        "cmd /c python android_ota\\android_ota_diag.py",
        "cmd.exe /c py android_ota\\android_ota_diag.py",
        '"C:\\Python311\\python.exe" android_ota\\android_ota_diag.py',
    ],
)
def test_launcher_interpreter_first_token_fails(tmp_path: Path, command: str) -> None:
    """Any batch line whose command token IS an interpreter must fail closed.

    Regression: a naive substring scan missed a bare ``py android_ota\\…py``
    (no ``-`` flag) launch — the operator ends up with a no-Python box that
    cannot run the tool. Detection is per-line first-token, allowing a leading
    ``call``.
    """
    members = _complete()
    members[LAUNCHER] = ("﻿@echo off\r\n" + command + "\r\npause\r\n").encode("utf-8")
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="interpreter"):
        MODULE.verify_qzx_bundle(path)


@pytest.mark.parametrize(
    "command",
    [
        "copy android_ota\\android_ota_diag.py backup.py",
        "xcopy android_ota /E /I",
        "echo 稍后可用 py 运行(仅提示)",
        "android_ota\\android_ota_diag.exe --human analyze %BUNDLE%",
    ],
)
def test_launcher_py_as_plain_text_passes(tmp_path: Path, command: str) -> None:
    """``py``/``python`` as an ARGUMENT or filename, not the command token,
    must not trip the gate (no substring false-positive)."""
    members = _complete()
    members[LAUNCHER] = ("﻿@echo off\r\n" + command + "\r\npause\r\n").encode("utf-8")
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    MODULE.verify_qzx_bundle(path)


def test_launcher_python_word_in_comment_passes(tmp_path: Path) -> None:
    members = _complete()
    members[LAUNCHER] = (
        "﻿@echo off\r\nrem 本工具无需安装 Python\r\n"
        "android_ota\\android_ota_diag.exe --human\r\npause\r\n"
    ).encode("utf-8")
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    # A comment mentioning Python is fine; only real invocation is rejected.
    MODULE.verify_qzx_bundle(path)


def test_missing_profile_fails(tmp_path: Path) -> None:
    members = _complete()
    del members["android_ota/profiles/qzx-yunos-4.4.json"]
    path = tmp_path / "tools.zip"
    path.write_bytes(_bundle(members))
    with pytest.raises(ValueError, match="qzx-yunos-4.4.json"):
        MODULE.verify_qzx_bundle(path)


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
