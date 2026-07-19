#!/usr/bin/env python3
"""Evidence-honesty contract for the Chinese --human OTA report.

The report a field operator reads must never upgrade a lone PackageManager
``Success`` line into a claim that the OTA activated. Without a matching
versionCode and time-correlated stage evidence, the receipt is 不确定 /
无法证明升级成功, per the daemon-honesty rule.
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest


SCRIPT = Path(__file__).resolve().parents[1] / "android_ota_diag.py"
QZX_PROFILE_PATH = (
    Path(__file__).resolve().parents[1] / "android_ota_profiles" / "qzx-yunos-4.4.json"
)
SPEC = importlib.util.spec_from_file_location("android_ota_diag", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

QZX_PROFILE = {
    "schema": "android-ota-profile/v1",
    "name": "qzx-yunos-4.4",
    "package": "com.jieoz.lanmediawall.player",
    "pm": {"success_lines": ["Success"], "fallback_on_exact_lines": {}},
}


def _human(files: dict[str, str]) -> str:
    result = MODULE.analyze(files, QZX_PROFILE)
    return MODULE.human_report(result, QZX_PROFILE)


def test_lone_success_is_not_claimed_as_upgrade_success() -> None:
    report = _human({"pm.txt": "Success\n"})
    # The verdict line must be honest: inconclusive, NOT proven success.
    assert "无法证明" in report or "不确定" in report
    assert "确认升级成功" not in report
    assert "升级已完成" not in report
    # It must state WHY: no versionCode / stage correlation.
    assert "versionCode" in report or "阶段" in report


def test_success_with_versioncode_and_stages_reports_receipt_with_caveat() -> None:
    report = _human({
        "log.txt": (
            "UPDATE_STAGE=download\nUPDATE_STAGE=pm_install\n"
            "versionCode=1181\nSuccess\n"
        ),
    })
    # The verdict must be the corroborated-success branch, not lone-success and
    # not inconclusive. Pin the exact target-branch headline: `versionCode` and
    # `回执` appear in every report header, so asserting only those is virtually
    # green — assert the branch-specific sentence instead.
    assert "判定结论:观察到 PackageManager 成功回执(需进一步佐证)" in report
    assert "→ 拿到了 PackageManager 成功回执,且日志含 versionCode 与安装阶段。" in report
    # Even corroborated, the honesty caveat about binding the receipt to the
    # requested APK/time must remain — never an unconditional success claim.
    assert "才能把这条回执绑定到本次升级" in report
    assert "确认升级成功" not in report
    assert "升级已完成" not in report
    # And it must NOT collapse into the lone-success inconclusive sentence.
    assert "无法证明本次 OTA 升级成功" not in report


def test_pm_failure_is_reported_as_failure_not_success() -> None:
    report = _human({
        "log.txt": "UPDATE_STAGE=pm_install\nFailure [INSTALL_FAILED_OLDER_SDK]\n",
    })
    # Pin the specific failure verdict branch, not a bare "失败" keyword that a
    # limitations blurb could satisfy on an unrelated verdict.
    assert "判定结论:PackageManager 安装失败" in report
    assert "→ PackageManager 明确返回失败,本次升级未成功。" in report
    # The PM failure evidence line must surface the actual receipt.
    assert "Failure [INSTALL_FAILED_OLDER_SDK]" in report
    # Must never claim any form of success for a hard PM failure.
    assert "成功回执" not in report
    assert "确认升级成功" not in report


def test_report_is_chinese_and_lists_input_files() -> None:
    report = _human({"device.txt": "Success\n"})
    assert "device.txt" in report
    # A few anchor Chinese labels the operator relies on.
    assert "判定" in report or "结论" in report


def test_cli_subprocess_human_analyze_is_utf8_and_honest(tmp_path: Path) -> None:
    """Run the tool exactly as the .bat does: a real subprocess with the shipped
    profile, ``--human analyze <bundle>``. Assert rc=0, strictly-UTF-8 stdout,
    the honest lone-Success conclusion, and that the input filename is listed.
    """
    bundle = tmp_path / "device_diag"
    bundle.mkdir()
    (bundle / "pm_output.txt").write_text("Success\n", encoding="utf-8")

    proc = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--profile",
            str(QZX_PROFILE_PATH),
            "--human",
            "analyze",
            str(bundle),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.returncode == 0, proc.stderr.decode("utf-8", "replace")
    # stdout must be STRICT UTF-8 (the .bat redirects it to *-OTA检测结果.txt);
    # a decode error here would mean garbled Chinese on the operator's box.
    text = proc.stdout.decode("utf-8")
    # Honest lone-Success verdict — never an upgrade-success claim.
    assert "无法证明本次 OTA 升级成功" in text
    assert "确认升级成功" not in text
    assert "升级已完成" not in text
    # The analyzed input file must be named back to the operator.
    assert "pm_output.txt" in text
    # Chinese report anchors the operator relies on.
    assert "判定结论" in text and "Android OTA 离线诊断结果" in text


def test_cli_subprocess_pm_failure_returns_zero_and_reports_failure(tmp_path: Path) -> None:
    """A detected PM failure is a successful ANALYSIS (rc=0) with an honest
    failure verdict — the tool exiting non-zero would mislead the .bat's
    ``ERRORLEVEL`` branch into a generic 'detector crashed' message."""
    bundle = tmp_path / "diag"
    bundle.mkdir()
    (bundle / "log.txt").write_text(
        "UPDATE_STAGE=pm_install\nFailure [INSTALL_FAILED_OLDER_SDK]\n",
        encoding="utf-8",
    )
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--profile", str(QZX_PROFILE_PATH),
         "--human", "analyze", str(bundle)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    assert proc.returncode == 0, proc.stderr.decode("utf-8", "replace")
    text = proc.stdout.decode("utf-8")
    assert "→ PackageManager 明确返回失败,本次升级未成功。" in text
    assert "log.txt" in text


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
