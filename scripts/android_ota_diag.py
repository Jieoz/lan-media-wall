#!/usr/bin/env python3
"""Profile-driven Android OTA evidence analysis and PackageManager simulation.

The core deliberately knows no product package, daemon hash, Android version, or
vendor filesystem. A profile supplies those platform facts and the accepted
PackageManager outcomes. This supports stock Android and vendor forks without
copying one-off field scripts.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path
from typing import Any


STAGES = ("guard", "download", "sha256", "staged", "daemon_probe", "pm_install", "restart_app", "legacy_stage")


def load_profile(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    required = {"schema", "name", "pm"}
    if data.get("schema") != "android-ota-profile/v1" or not required <= data.keys():
        raise ValueError(f"invalid Android OTA profile: {path}")
    pm = data["pm"]
    if not isinstance(pm.get("success_lines"), list) or not isinstance(pm.get("fallback_on_exact_lines"), dict):
        raise ValueError(f"invalid pm rules in profile: {path}")
    return data


def pm_decision(output: str, profile: dict[str, Any]) -> dict[str, Any]:
    lines = {line.strip() for line in output.splitlines() if line.strip()}
    pm = profile["pm"]
    success = next((line for line in pm["success_lines"] if line in lines), None)
    fallback = next((action for line, action in pm["fallback_on_exact_lines"].items() if line in lines), None)
    failure = next((line for line in output.splitlines() if line.strip().startswith(("Failure", "Error:"))), None)
    if success:
        return {"decision": "activated", "evidence": success, "fallback": None}
    if fallback:
        return {"decision": "fallback", "evidence": fallback, "fallback": fallback}
    return {"decision": "failed", "evidence": failure.strip() if failure else "no-recognized-pm-receipt", "fallback": None}


def read_bundle(path: Path) -> dict[str, str]:
    if path.is_dir():
        return {str(item.relative_to(path)): item.read_text(encoding="utf-8", errors="replace")
                for item in path.rglob("*") if item.is_file()}
    with zipfile.ZipFile(path) as archive:
        return {name: archive.read(name).decode("utf-8", "replace")
                for name in archive.namelist() if not name.endswith("/")}


def analyze(files: dict[str, str], profile: dict[str, Any]) -> dict[str, Any]:
    text = "\n".join(files.values())
    observed = [stage for stage in STAGES if re.search(rf"UPDATE_STAGE={re.escape(stage)}\b", text)]
    # Daemon output can arrive as a log line even where AppUpdater stage text was
    # lost. The profile, not the core, decides what an exact PM outcome means.
    decision = pm_decision(text, profile)
    package = profile.get("package")
    version_match = re.search(r"versionCode[=': ]+(\d+)", text)
    result = {
        "schema": "android-ota-diagnostic/v1",
        "profile": profile["name"],
        "input_files": sorted(files),
        "observed_stages": observed,
        "package": package,
        "version_code": int(version_match.group(1)) if version_match else None,
        "pm": decision,
        "verdict": "inconclusive",
        "limitations": [],
    }
    if decision["decision"] == "activated":
        result["verdict"] = "package_manager_success_receipt_observed"
        result["limitations"].append(
            "Success alone does not bind this receipt to the requested APK; require matching versionCode and time-correlated stage evidence to prove activation."
        )
    elif decision["decision"] == "fallback":
        result["verdict"] = "fallback_activation_required"
    elif "pm_install" in observed:
        result["verdict"] = "package_manager_failed"
    elif observed:
        result["verdict"] = "stopped_before_package_manager_receipt"
    else:
        result["limitations"].append("No stable OTA stage or PackageManager receipt was captured.")
    if "download" not in observed:
        result["limitations"].append("Control-plane/download evidence is absent or not in the bundle.")
    if decision["decision"] != "activated":
        result["limitations"].append("A device PackageManager receipt is required to prove activation.")
    return result


# --- Human-readable Chinese report ------------------------------------------
# The field operator double-clicks a launcher and reads THIS. The cardinal rule
# (§Success-honesty): a lone PackageManager `Success` line, absent a matching
# versionCode AND time-correlated stage evidence, is NOT proof the OTA upgrade
# activated — it is 不确定 / 无法证明升级成功. The report never converts such a
# receipt into "升级已完成/确认升级成功".
_VERDICT_LABELS = {
    "package_manager_success_receipt_observed": "观察到 PackageManager 成功回执(需进一步佐证)",
    "fallback_activation_required": "需要 fallback 激活路径",
    "package_manager_failed": "PackageManager 安装失败",
    "stopped_before_package_manager_receipt": "在拿到 PackageManager 回执前中止",
    "inconclusive": "证据不足,无法判定",
}


def human_report(result: dict[str, Any], profile: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("===== Android OTA 离线诊断结果 =====")
    lines.append(f"使用 profile:{result.get('profile')}(包名:{result.get('package') or '未知'})")
    lines.append("")
    files = result.get("input_files") or []
    lines.append(f"已分析文件({len(files)} 个):")
    for name in files:
        lines.append(f"  - {name}")
    if not files:
        lines.append("  (无)")
    lines.append("")
    stages = result.get("observed_stages") or []
    lines.append(f"观察到的升级阶段:{'、'.join(stages) if stages else '无'}")
    version_code = result.get("version_code")
    lines.append(f"日志中的 versionCode:{version_code if version_code is not None else '未出现'}")
    pm = result.get("pm") or {}
    lines.append(f"PackageManager 回执:{pm.get('decision')}(证据:{pm.get('evidence')})")
    lines.append("")

    verdict = result.get("verdict", "inconclusive")
    lines.append(f"判定结论:{_VERDICT_LABELS.get(verdict, verdict)}")

    # The honest headline. A success RECEIPT is never an upgrade-success CLAIM
    # unless versionCode + stage evidence corroborate it — and even then the
    # binding to the requested APK is only asserted, so the caveat stays.
    if verdict == "package_manager_success_receipt_observed":
        proven = version_code is not None and ("pm_install" in stages)
        if proven:
            lines.append(
                "→ 拿到了 PackageManager 成功回执,且日志含 versionCode 与安装阶段。"
                "但仍需核对该 versionCode 与目标 APK 是否一致、时间是否吻合,"
                "才能把这条回执绑定到本次升级。"
            )
        else:
            lines.append(
                "→ 仅有一条 PackageManager `Success` 回执,缺少匹配的 versionCode 或"
                "时间吻合的升级阶段证据,无法证明本次 OTA 升级成功,判定为不确定。"
            )
    elif verdict == "package_manager_failed":
        lines.append("→ PackageManager 明确返回失败,本次升级未成功。")
    elif verdict == "fallback_activation_required":
        lines.append("→ 命中厂商 fallback 规则,需要走 fallback 激活路径。")
    elif verdict == "stopped_before_package_manager_receipt":
        lines.append("→ 有升级阶段痕迹,但没有 PackageManager 回执,升级结果不确定。")
    else:
        lines.append("→ 未捕获到稳定的升级阶段或 PackageManager 回执,无法判定。")

    limitations = result.get("limitations") or []
    if limitations:
        lines.append("")
        lines.append("局限与注意:")
        for item in limitations:
            lines.append(f"  * {item}")
    lines.append("")
    lines.append("提示:本判定仅基于所提供的日志/诊断包。要证明升级成功,"
                 "需设备侧 PackageManager 回执 + 匹配的 versionCode + 时间吻合的阶段证据三者齐备。")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--human", action="store_true",
                        help="print a Chinese human-readable report instead of JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("analyze", help="classify a diagnostic directory or ZIP")
    inspect.add_argument("bundle", type=Path)
    simulate = sub.add_parser("simulate", help="classify captured pm stdout/stderr")
    simulate.add_argument("pm_output", type=Path)
    args = parser.parse_args()
    profile = load_profile(args.profile)
    if args.command == "analyze":
        result = analyze(read_bundle(args.bundle), profile)
    else:
        result = {"schema": "android-ota-diagnostic/v1", "profile": profile["name"],
                  "pm": pm_decision(args.pm_output.read_text(encoding="utf-8", errors="replace"), profile)}
    if args.human and args.command == "analyze":
        text = human_report(result, profile)
        # UTF-8 bytes so redirection to a file (the .bat writes *-OTA检测结果.txt)
        # keeps Chinese intact regardless of the Windows console code page.
        sys.stdout.buffer.write(text.encode("utf-8"))
        sys.stdout.buffer.write(b"\n")
    else:
        print(json.dumps(result, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())