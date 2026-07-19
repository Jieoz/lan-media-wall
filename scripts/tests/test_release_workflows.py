from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
BUILD_WORKFLOWS = (
    "ci.yml",
    "flutter-build.yml",
    "android-build.yml",
    "windows-build.yml",
    "broker-build.yml",
)


def _load(name: str) -> tuple[str, dict]:
    text = (WORKFLOWS / name).read_text(encoding="utf-8")
    return text, yaml.safe_load(text)


def test_build_workflows_run_on_every_main_sha_but_never_tags() -> None:
    for name in BUILD_WORKFLOWS:
        text, data = _load(name)
        trigger = data[True]["push"]
        assert trigger["branches"] == ["main"], name
        assert "tags" not in trigger, name
        assert "paths" not in trigger, name
        assert "action-gh-release" not in text, name
        assert data.get("permissions", {}).get("contents", "read") == "read", name


def test_release_workflow_is_tag_only_and_contains_no_build_commands() -> None:
    text, data = _load("release-promote.yml")
    trigger = data[True]
    assert trigger == {"push": {"tags": ["v*"]}}
    assert data["permissions"] == {"actions": "read", "contents": "write"}
    for forbidden in (
        "flutter build",
        "./gradlew",
        "assembleRelease",
        "pyinstaller",
        "pip install",
    ):
        assert forbidden not in text


def test_release_workflow_requires_all_five_verified_main_runs() -> None:
    text, _ = _load("release-promote.yml")
    for workflow in BUILD_WORKFLOWS:
        assert workflow in text
    assert "event: 'push'" in text
    assert "git rev-parse HEAD" in text
    assert "const sha = process.env.TARGET_SHA" in text
    assert "head_sha: sha" in text
    assert "TARGET_SHA: ${{ steps.target.outputs.sha }}" in text
    assert '--commit-sha "$TARGET_SHA"' in text
    assert 'CI_RUN_ID: ${{ steps.runs.outputs.ci }}' in text
    assert '--run "ci.yml=$CI_RUN_ID"' in text
    assert '--commit-sha "${{ steps.target.outputs.sha }}"' not in text
    assert '--commit-sha "${GITHUB_SHA}"' not in text
    assert "run.head_sha === sha" in text
    assert "run.head_branch === branch" in text
    assert "sha256sum --check SHA256SUMS" in text


# --- android-build: detector fail-closed but APK lane survives ---------------
_QZX_ONLY_STEPS = (
    "Download standalone OTA detector EXE",
    "Package QZX updater tools",
    "Verify QZX restart and package contracts",
    "Upload QZX updater tools",
)


def _android_jobs() -> dict:
    _text, data = _load("android-build.yml")
    return data["jobs"]


def _steps_by_name(job: dict) -> dict:
    return {s["name"]: s for s in job["steps"] if isinstance(s, dict) and "name" in s}


def test_detector_honesty_check_joins_output_before_matching() -> None:
    """PowerShell ``$array -notmatch <re>`` returns the FILTERED ARRAY, not a
    bool, so ``if ($out -notmatch ...)`` is truthy whenever any single line
    fails to match — the honesty gate then throws on every run. The output must
    be joined to ONE string (Out-String) before the ``-notmatch`` test."""
    text, _ = _load("android-build.yml")
    # The raw array form must be gone.
    assert "if ($out -notmatch" not in text, \
        "detector must not run -notmatch against the raw Tee-Object array"
    # The joined-string form must drive the honesty test.
    assert "$out | Out-String" in text
    assert "$joined -notmatch" in text


def test_build_job_runs_even_when_detector_fails() -> None:
    """The Android APK lane must not be washed out by a Windows/PyInstaller
    detector failure: `build` still depends on `ota-detector` (ordering + EXE
    artifact), but a `needs` job has an implicit `success()` condition unless
    it uses a status function. `always() && !cancelled()` therefore lets a
    detector failure through while respecting a cancelled workflow."""
    jobs = _android_jobs()
    build = jobs["build"]
    assert build.get("needs") == "ota-detector"
    cond = str(build.get("if", "")).replace(" ", "")
    assert "always()" in cond, f"build job must override implicit success(); got {build.get('if')!r}"
    assert "!cancelled()" in cond, f"build job must remain cancellable; got {build.get('if')!r}"


def test_apk_lane_steps_are_not_gated_on_detector_result() -> None:
    """APK build/test/upload steps gate ONLY on the Gradle-project presence —
    never on the detector job — so a detector outage still ships the APK."""
    build = _android_jobs()["build"]
    steps = _steps_by_name(build)
    for name in ("Build release APK", "Run Android JVM unit tests", "Upload release APK"):
        cond = str(steps[name].get("if", ""))
        assert cond.strip() == "steps.detect.outputs.present == 'true'", \
            f"APK step {name!r} must gate only on gradle presence; got {cond!r}"
        assert "ota-detector" not in cond


def test_qzx_steps_are_fail_closed_on_detector_success() -> None:
    """The QZX ZIP is fail-closed: every QZX-specific step (download the EXE,
    package, verify contracts, upload) runs ONLY when the detector job
    succeeded AND the gradle project is present. A detector failure must skip
    all four so no stale/missing QZX package can be produced or uploaded."""
    build = _android_jobs()["build"]
    steps = _steps_by_name(build)
    for name in _QZX_ONLY_STEPS:
        cond = str(steps[name]["if"]).replace(" ", "")
        assert "steps.detect.outputs.present=='true'" in cond, f"{name}: missing gradle gate"
        assert "needs.ota-detector.result=='success'" in cond, \
            f"QZX step {name!r} must require detector success; got {steps[name]['if']!r}"


def test_workflow_stays_red_when_detector_fails() -> None:
    """No job/step may swallow the detector failure: the whole android-build run
    must stay failed (so promotion, which requires a successful run, is gated)."""
    text, data = _load("android-build.yml")
    assert "continue-on-error" not in text, \
        "android-build must not use continue-on-error (would wash a detector failure green)"
    # ota-detector is a real job that fails closed on a bad build.
    assert "ota-detector" in data["jobs"]
