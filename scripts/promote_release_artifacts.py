#!/usr/bin/env python3
"""Validate and promote immutable CI artifacts into versioned release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path


ARTIFACTS = (
    ("lmw-broker", "lmw-broker", "Broker-Linux", ""),
    ("lmw-broker.exe", "lmw-broker.exe", "Broker-Windows", ".exe"),
    (
        "lan-media-wall-player-android-release",
        "*.apk",
        "Player-Android",
        ".apk",
    ),
    (
        "lan-media-wall-qzx-update-tools",
        "*.zip",
        "QZX-Update-Tools",
        ".zip",
    ),
    (
        "lan-media-wall-controller-android-release",
        "*arm64-v8a*-release.apk",
        "Controller-ARM64-v8a",
        ".apk",
    ),
    (
        "lan-media-wall-controller-android-release",
        "*armeabi-v7a*-release.apk",
        "Controller-ARMv7",
        ".apk",
    ),
    (
        "lan-media-wall-controller-android-release",
        "*x86_64*-release.apk",
        "Controller-x86_64",
        ".apk",
    ),
    (
        "lan-media-wall-player-windows-setup",
        "*.exe",
        "Player-Windows-Setup",
        ".exe",
    ),
)


def validate_tag(tag: str, pubspec: Path) -> tuple[str, int]:
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)", tag)
    if not match:
        raise ValueError(f"invalid release tag: {tag!r}")

    version_match = re.search(
        r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$",
        pubspec.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not version_match:
        raise ValueError(f"missing X.Y.Z+N version in {pubspec}")

    version, build = version_match.group(1), int(version_match.group(2))
    if match.group(1) != version:
        raise ValueError(f"tag {tag} does not match pubspec version {version}")
    return version, build


def _find_one(source: Path, artifact: str, pattern: str) -> Path:
    root = source / artifact
    if not root.is_dir():
        raise ValueError(f"missing artifact directory: {artifact}")
    matches = [path for path in root.rglob(pattern) if path.is_file()]
    if not matches:
        raise ValueError(f"missing artifact file: {artifact}/{pattern}")
    if len(matches) != 1:
        raise ValueError(
            f"artifact {artifact!r} pattern {pattern!r}: expected exactly one "
            f"file, found {len(matches)}"
        )
    if matches[0].stat().st_size == 0:
        raise ValueError(f"artifact file is empty: {matches[0]}")
    return matches[0]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def promote(source: Path, output: Path, tag: str) -> list[Path]:
    if not source.is_dir():
        raise ValueError(f"artifact source directory does not exist: {source}")

    expected_directories = {artifact for artifact, *_ in ARTIFACTS}
    actual_directories = {path.name for path in source.iterdir() if path.is_dir()}
    unexpected_directories = actual_directories - expected_directories
    if unexpected_directories:
        raise ValueError(
            f"unexpected artifact directories: {sorted(unexpected_directories)}"
        )

    selected: list[tuple[Path, str, str]] = []
    consumed: set[Path] = set()
    for artifact, pattern, label, extension in ARTIFACTS:
        src = _find_one(source, artifact, pattern)
        selected.append((src, label, extension))
        consumed.add(src.resolve())

    all_files = {path.resolve() for path in source.rglob("*") if path.is_file()}
    unmapped_files = sorted(str(path.relative_to(source.resolve())) for path in all_files - consumed)
    if unmapped_files:
        raise ValueError(f"unmapped artifact files: {unmapped_files}")

    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError(f"release output directory is not empty: {output}")

    promoted: list[Path] = []
    for src, label, extension in selected:
        dst = output / f"LANMediaWall-{tag}-{label}{extension}"
        shutil.copy2(src, dst)
        promoted.append(dst)

    checksum_path = output / "SHA256SUMS"
    lines = [f"{_sha256(path)}  {path.name}" for path in sorted(promoted)]
    checksum_path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return promoted


def write_provenance(
    output: Path,
    *,
    tag: str,
    commit_sha: str,
    version: str,
    build: int,
    runs: dict[str, int],
) -> Path:
    if not re.fullmatch(r"[0-9a-f]{40}", commit_sha):
        raise ValueError("commit SHA must be a full 40-character lowercase hex value")
    expected = {
        "ci.yml",
        "flutter-build.yml",
        "android-build.yml",
        "windows-build.yml",
        "broker-build.yml",
    }
    if set(runs) != expected or any(not isinstance(value, int) or value <= 0 for value in runs.values()):
        raise ValueError(f"workflow runs must contain positive IDs for {sorted(expected)}")

    path = output / "RELEASE_PROVENANCE.json"
    payload = {
        "tag": tag,
        "commit_sha": commit_sha,
        "version": version,
        "build": build,
        "workflow_runs": runs,
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit-sha", required=True)
    parser.add_argument(
        "--run",
        action="append",
        required=True,
        metavar="WORKFLOW=RUN_ID",
        help="repeat once for each required build workflow",
    )
    parser.add_argument(
        "--pubspec", type=Path, default=Path("remote_flutter/pubspec.yaml")
    )
    args = parser.parse_args()

    version, build = validate_tag(args.tag, args.pubspec)
    promoted = promote(args.source, args.output, args.tag)
    try:
        runs = {name: int(run_id) for name, run_id in (item.split("=", 1) for item in args.run)}
    except (ValueError, TypeError) as exc:
        raise ValueError("each --run must be WORKFLOW=RUN_ID") from exc
    provenance = write_provenance(
        args.output,
        tag=args.tag,
        commit_sha=args.commit_sha,
        version=version,
        build=build,
        runs=runs,
    )
    print(f"validated {args.tag}: version={version}, build={build}")
    for path in promoted:
        print(f"promoted {path.name}: {path.stat().st_size} bytes")
    print(f"wrote {args.output / 'SHA256SUMS'}")
    print(f"wrote {provenance}")


if __name__ == "__main__":
    main()
