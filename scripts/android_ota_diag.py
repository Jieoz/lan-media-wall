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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, type=Path)
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
    print(json.dumps(result, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())