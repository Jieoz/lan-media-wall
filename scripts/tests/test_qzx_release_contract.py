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
print("QZX_RELEASE_CONTRACT_PASS")
