#!/usr/bin/env python3
"""Validate and promote immutable CI artifacts into versioned release assets."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
from pathlib import Path


def _load_qzx_bundle_contract():
    """Load the pure QZX bundle gate as a sibling module (no package needed)."""
    path = Path(__file__).resolve().parent / "qzx_bundle_contract.py"
    spec = importlib.util.spec_from_file_location("qzx_bundle_contract", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_QZX_CONTRACT = _load_qzx_bundle_contract()


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
    (
        "lan-media-wall-controller-windows",
        "*.zip",
        "Controller-Windows-x64",
        ".zip",
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


def _tool_path(command: str, label: str) -> str:
    path = shutil.which(command) if "/" not in command else command
    if not path or not Path(path).is_file():
        raise ValueError(f"{label} executable not found: {command}")
    return path


def _normalise_cert(value: str) -> str:
    return re.sub(r"[^0-9a-f]", "", value.lower())


# Flutter `flutter build apk --split-per-abi` derives a per-ABI versionCode of
# `abiOffset + baseBuild` so each split APK carries a distinct, monotonically
# comparable code on the Play Store. These are Flutter's built-in offsets
# (flutter.gradle: armeabi-v7a=1, arm64-v8a=2, x86_64=4, each *1000). The native
# Android Player is NOT split-per-abi, so its APK uses the raw build number.
# Real v1.14.13 CI artifacts confirmed this: player=61, controllers=1061/2061/4061.
_ABI_VERSION_CODE_OFFSET = {
    "armeabi-v7a": 1000,
    "arm64-v8a": 2000,
    "x86_64": 4000,
}


def _expected_version_code(apk_name: str, build: int) -> int:
    """Expected versionCode for one APK, from its ABI marker in the filename.

    Split controller APKs are named e.g. ``app-arm64-v8a-release.apk`` and get
    the Flutter ABI offset; the non-split player APK (``app-release.apk``) has
    no ABI marker and keeps the raw build number.
    """
    matched = [abi for abi in _ABI_VERSION_CODE_OFFSET if abi in apk_name]
    if len(matched) > 1:
        raise ValueError(f"{apk_name}: ambiguous ABI markers {sorted(matched)}")
    offset = _ABI_VERSION_CODE_OFFSET[matched[0]] if matched else 0
    return offset + build


def verify_android_apks(
    source: Path,
    *,
    version: str,
    build: int,
    expected_cert_sha256: str,
    aapt2: str,
    apksigner: str,
    runner=subprocess.run,
) -> None:
    if not expected_cert_sha256.strip():
        raise ValueError("expected signer certificate SHA-256 is required")
    if runner is subprocess.run:
        aapt2 = _tool_path(aapt2, "aapt2")
        apksigner = _tool_path(apksigner, "apksigner")
    expected_cert = _normalise_cert(expected_cert_sha256)
    if len(expected_cert) != 64:
        raise ValueError("expected signer certificate SHA-256 must contain 64 hex digits")
    apks = sorted(source.rglob("*.apk"))
    if not apks:
        raise ValueError("no Android APKs found for internal verification")
    for apk in apks:
        expected_code = _expected_version_code(apk.name, build)
        badging = runner([aapt2, "dump", "badging", str(apk)], check=True,
                         text=True, capture_output=True).stdout
        metadata = re.search(
            r"^package:.*versionCode='(\d+)'.*versionName='([^']+)'", badging,
            re.MULTILINE,
        )
        if not metadata or metadata.group(2) != version or int(metadata.group(1)) != expected_code:
            raise ValueError(
                f"{apk}: versionName/versionCode mismatch; "
                f"expected {version}/{expected_code}"
            )
        certs = runner([apksigner, "verify", "--print-certs", str(apk)], check=True,
                       text=True, capture_output=True).stdout
        digests = re.findall(r"certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)", certs)
        if len(digests) != 1 or _normalise_cert(digests[0]) != expected_cert:
            raise ValueError(f"{apk}: signer certificate SHA-256 mismatch")


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
        # Fail closed before publishing: the QZX ZIP must carry the Chinese
        # launcher (BOM+CRLF, no interpreter), a real PE detector EXE, the
        # Python source, and both profiles.
        if label == "QZX-Update-Tools":
            _QZX_CONTRACT.verify_qzx_bundle(src)
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
    parser.add_argument("--expected-cert-sha256", required=True)
    parser.add_argument("--aapt2", required=True)
    parser.add_argument("--apksigner", required=True)
    args = parser.parse_args()

    version, build = validate_tag(args.tag, args.pubspec)
    verify_android_apks(
        args.source,
        version=version,
        build=build,
        expected_cert_sha256=args.expected_cert_sha256,
        aapt2=args.aapt2,
        apksigner=args.apksigner,
    )
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
