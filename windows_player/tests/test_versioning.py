from pathlib import Path
import sys

import pytest

import versioning


def test_read_release_version_from_pubspec(tmp_path: Path):
    pubspec = tmp_path / "pubspec.yaml"
    pubspec.write_text("name: example\nversion: 1.13.8+40\n", encoding="utf-8")

    assert versioning.read_release_version([pubspec]) == ("1.13.8", 40)


def test_read_release_version_rejects_missing_or_malformed(tmp_path: Path):
    malformed = tmp_path / "pubspec.yaml"
    malformed.write_text("version: latest\n", encoding="utf-8")

    with pytest.raises(RuntimeError, match="release version not found"):
        versioning.read_release_version([malformed, tmp_path / "missing.yaml"])


def test_candidate_pubspecs_prefer_pyinstaller_bundle(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    bundled = tmp_path / "pubspec.yaml"
    bundled.write_text("version: 1.13.8+40\n", encoding="utf-8")

    candidates = list(versioning._candidate_pubspecs())

    assert candidates[0] == bundled
    assert versioning.read_release_version(candidates) == ("1.13.8", 40)
