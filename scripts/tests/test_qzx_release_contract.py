#!/usr/bin/env python3
"""Static release contract for the real-device restart harness and QZX bundle."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sh = (ROOT / "scripts/qzx_field_check.sh").read_text(encoding="utf-8")
bat = (ROOT / "scripts/qzx_field_check.bat").read_text(encoding="utf-8")
workflow = (ROOT / ".github/workflows/android-build.yml").read_text(encoding="utf-8")
for stale in ('trigger="manual"', "MANUAL CHECKPOINT", "PASS-with-caveat"):
    assert stale not in sh, f"shell harness retains unsafe fallback: {stale}"
    assert stale not in bat, f"Windows harness retains unsafe fallback: {stale}"
assert ' -restart 2>&1 || ' not in bat, "Windows harness may execute restart worker twice"
assert 'if [ "$trigger" = "daemon" ]' in sh
assert 'if "%DAEMON_PRESENT%"=="yes" if "%DAEMON_RC%"=="0"' in bat
for required in ("qzx_field_check.bat", "qzx_field_check.sh", "lmw_root_daemon"):
    assert workflow.count(required) >= 2, f"{required} must be copied and zipped"
for required in (
    "android_ota/android_ota_diag.py",
    "android_ota/profiles/standard-pm.json",
    "android_ota/profiles/qzx-yunos-4.4.json",
    "scripts/tests/test_android_ota_simulator.c",
):
    assert required in workflow, f"{required} must be present in android-build workflow"

# Windows no-Python OTA detector wiring: a dedicated Windows job builds the real
# PE EXE with a PINNED PyInstaller, the build job consumes it (never rebuilt at
# tag time), the Chinese launcher + EXE ship in the ZIP, and the fail-closed
# bundle contract gates the package.
for required in (
    "ota-detector:",
    "runs-on: windows-2022",
    "pyinstaller==6.11.1",
    "--onefile",
    "lan-media-wall-ota-detector",
    "needs: ota-detector",
    "Download standalone OTA detector EXE",
    "android_ota/android_ota_diag.exe",
    "OTA检测.bat",
    "scripts/qzx_bundle_contract.py",
):
    assert required in workflow, f"{required} must be present in android-build workflow"

# The launcher on disk must itself satisfy the shippable-launcher byte contract.
bat_bytes = (ROOT / "scripts/OTA检测.bat").read_bytes()
assert bat_bytes.startswith(b"\xef\xbb\xbf"), "OTA检测.bat must start with a UTF-8 BOM"
assert b"\r\n" in bat_bytes and bat_bytes[3:].replace(b"\r\n", b"").count(b"\n") == 0, \
    "OTA检测.bat must use CRLF line endings"
assert b"\n" not in bat_bytes.replace(b"\r\n", b""), "OTA检测.bat must have no bare LF"

# Every early error path must funnel through ONE failure handler that keeps
# `pause` for interactive use yet returns nonzero for unattended invocation.
# A fragile inline branch that exits 0 (the old `:hold` tail) would tell an
# automation harness the check passed when the detector never ran.
ota_bat_text = bat_bytes[3:].decode("utf-8")  # drop BOM
assert ":fail" in ota_bat_text, "OTA检测.bat must define a common :fail handler"
# The old exit-0 catch-all must be gone: no error path may fall through to :eof
# without a nonzero code.
assert ota_bat_text.count("goto :hold") == 0, \
    "OTA检测.bat must not route errors through the exit-0 :hold tail"
# Every early-error branch jumps to the common failure handler.
assert ota_bat_text.count("goto :fail") >= 5, \
    "every early error path must goto :fail"
# The failure handler returns nonzero for unattended callers.
assert "exit /b 1" in ota_bat_text, "OTA检测.bat :fail handler must exit nonzero"
# `pause` is preserved for the interactive operator.
assert "pause" in ota_bat_text, "OTA检测.bat must keep pause for interactive use"
# Unattended mode must not hang on pause — it skips straight to the exit.
assert "LMW_OTA_NONINTERACTIVE" in ota_bat_text, \
    "OTA检测.bat must still branch on LMW_OTA_NONINTERACTIVE for unattended runs"
# On a detector failure the UI points operators at RESULT, so stderr must be
# captured there too rather than disappearing from the promised diagnostic file.
assert '> "%RESULT%" 2>&1' in ota_bat_text, \
    "OTA检测.bat must redirect detector stderr into the referenced result file"

# The byte contract above only holds if Git is told NOT to normalise this file.
# `-text` disables text conversion (CRLF↔LF, BOM stripping) on checkout/checkin,
# so the shipped launcher keeps its exact UTF-8 BOM + CRLF bytes on every OS.
gitattributes = (ROOT / ".gitattributes")
assert gitattributes.is_file(), ".gitattributes must exist to pin OTA检测.bat bytes"
ga_lines = gitattributes.read_text(encoding="utf-8").splitlines()
assert "scripts/OTA检测.bat -text" in ga_lines, \
    ".gitattributes must carry the exact entry 'scripts/OTA检测.bat -text'"

# release-promote must fetch the Android artifacts BY NAME so the intermediate
# ota-detector EXE artifact never reaches promotion (no unexpected dir, no
# rebuild), while the release APK is still downloaded.
promote_wf = (ROOT / ".github/workflows/release-promote.yml").read_text(encoding="utf-8")
for required in (
    "name: lan-media-wall-qzx-update-tools",
    "name: lan-media-wall-player-android-release",
):
    assert required in promote_wf, f"{required} must be named in release-promote workflow"
assert "lan-media-wall-ota-detector" not in promote_wf, \
    "release-promote must NOT download the intermediate OTA detector artifact"
print("QZX_RELEASE_CONTRACT_PASS")
