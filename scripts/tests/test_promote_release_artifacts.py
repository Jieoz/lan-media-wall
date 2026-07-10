import importlib.util
import json
from pathlib import Path

import pytest


SCRIPT = Path(__file__).resolve().parents[1] / "promote_release_artifacts.py"
SPEC = importlib.util.spec_from_file_location("promote_release_artifacts", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def _write(root: Path, relative: str, data: bytes = b"artifact") -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _complete_artifacts(root: Path) -> None:
    _write(root, "lmw-broker/lmw-broker", b"broker-linux")
    _write(root, "lmw-broker.exe/lmw-broker.exe", b"broker-windows")
    _write(root, "lan-media-wall-player-android-release/app-release.apk", b"player")
    _write(root, "lan-media-wall-qzx-update-tools/LANMediaWall-QZX-Update-Tools.zip", b"tools")
    _write(root, "lan-media-wall-controller-android-release/app-arm64-v8a-release.apk", b"arm64")
    _write(root, "lan-media-wall-controller-android-release/app-armeabi-v7a-release.apk", b"armv7")
    _write(root, "lan-media-wall-controller-android-release/app-x86_64-release.apk", b"x86")
    _write(root, "lan-media-wall-player-windows-setup/lan-media-wall-player-setup.exe", b"windows-player")


def test_validate_tag_matches_pubspec_version(tmp_path: Path) -> None:
    pubspec = tmp_path / "pubspec.yaml"
    pubspec.write_text("name: remote_flutter\nversion: 1.13.10+42\n", encoding="utf-8")

    assert MODULE.validate_tag("v1.13.10", pubspec) == ("1.13.10", 42)

    with pytest.raises(ValueError, match="does not match pubspec"):
        MODULE.validate_tag("v1.13.9", pubspec)


def test_promote_maps_exact_eight_assets_and_writes_checksums(tmp_path: Path) -> None:
    source = tmp_path / "artifacts"
    output = tmp_path / "release"
    _complete_artifacts(source)

    promoted = MODULE.promote(source, output, "v1.13.10")

    names = sorted(path.name for path in promoted)
    assert names == sorted([
        "LANMediaWall-v1.13.10-Broker-Linux",
        "LANMediaWall-v1.13.10-Broker-Windows.exe",
        "LANMediaWall-v1.13.10-Controller-ARM64-v8a.apk",
        "LANMediaWall-v1.13.10-Controller-ARMv7.apk",
        "LANMediaWall-v1.13.10-Controller-x86_64.apk",
        "LANMediaWall-v1.13.10-Player-Android.apk",
        "LANMediaWall-v1.13.10-Player-Windows-Setup.exe",
        "LANMediaWall-v1.13.10-QZX-Update-Tools.zip",
    ])
    checksums = (output / "SHA256SUMS").read_text(encoding="ascii").splitlines()
    assert len(checksums) == 8
    assert all("  LANMediaWall-v1.13.10-" in line for line in checksums)


def test_write_provenance_records_exact_commit_and_runs(tmp_path: Path) -> None:
    output = tmp_path / "release"
    output.mkdir()
    runs = {
        "ci.yml": 100,
        "flutter-build.yml": 101,
        "android-build.yml": 102,
        "windows-build.yml": 103,
        "broker-build.yml": 104,
    }

    path = MODULE.write_provenance(
        output,
        tag="v1.13.10",
        commit_sha="a" * 40,
        version="1.13.10",
        build=42,
        runs=runs,
    )

    data = json.loads(path.read_text(encoding="utf-8"))
    assert data == {
        "tag": "v1.13.10",
        "commit_sha": "a" * 40,
        "version": "1.13.10",
        "build": 42,
        "workflow_runs": runs,
    }

    with pytest.raises(ValueError, match="full 40-character"):
        MODULE.write_provenance(
            output,
            tag="v1.13.10",
            commit_sha="abc",
            version="1.13.10",
            build=42,
            runs=runs,
        )


def test_promote_rejects_unknown_artifact_directory(tmp_path: Path) -> None:
    source = tmp_path / "artifacts"
    output = tmp_path / "release"
    _complete_artifacts(source)
    _write(source, "unexpected-build/payload.bin", b"unknown")

    with pytest.raises(ValueError, match="unexpected artifact directories"):
        MODULE.promote(source, output, "v1.13.10")


def test_promote_rejects_unmapped_file(tmp_path: Path) -> None:
    source = tmp_path / "artifacts"
    output = tmp_path / "release"
    _complete_artifacts(source)
    _write(source, "lmw-broker/debug-symbols.txt", b"unknown")

    with pytest.raises(ValueError, match="unmapped artifact files"):
        MODULE.promote(source, output, "v1.13.10")


def test_promote_rejects_missing_artifact(tmp_path: Path) -> None:
    source = tmp_path / "artifacts"
    output = tmp_path / "release"
    _complete_artifacts(source)
    (source / "lmw-broker/lmw-broker").unlink()

    with pytest.raises(ValueError, match="missing artifact"):
        MODULE.promote(source, output, "v1.13.10")


def test_promote_rejects_ambiguous_artifact(tmp_path: Path) -> None:
    source = tmp_path / "artifacts"
    output = tmp_path / "release"
    _complete_artifacts(source)
    _write(source, "lmw-broker/copy/lmw-broker", b"duplicate")

    with pytest.raises(ValueError, match="expected exactly one"):
        MODULE.promote(source, output, "v1.13.10")
