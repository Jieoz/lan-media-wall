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
