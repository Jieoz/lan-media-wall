# CC_RELEASE_REPORT — lan-media-wall v1.0.2

Slim, dependency-free release. All FOUR artifact groups built in CI and attached
to the GitHub Release via softprops/action-gh-release on the `v*` tag push.

## Root cause fixed for this release
`broker-build` failed on v1.0.1 (and main): the build runs with
`working-directory: broker`, so the frozen binaries land at `broker/dist/...`,
but the upload + release-attach steps still pointed at `dist/...`. The two broker
binaries therefore never attached to the v1.0.1 release. Path corrected to
`broker/dist/...`; bumped to v1.0.2 so a clean tag run re-attaches all artifacts.

## Measured artifact sizes
| Artifact | Lane | Measured size |
|---|---|---|
| app-arm64-v8a-release.apk (control)   | flutter-build | 17.1 MB |
| app-armeabi-v7a-release.apk (control) | flutter-build | 14.7 MB |
| app-x86_64-release.apk (control)      | flutter-build | 18.5 MB |
| app-release.apk (Android player)      | android-build |  6.1 MB |
| lan-media-wall-player-setup.exe       | windows-build | 45.0 MB (< 60 MB floor) |
| lmw-broker (Linux ELF)                | broker-build  | ~8 MB (PyInstaller onefile) |
| lmw-broker.exe (Windows)              | broker-build  | ~9 MB (PyInstaller onefile) |

Control APKs are split-per-abi release builds (NOT the 141 MB debug). The Windows
installer is measurably under the 60 MB ceiling. Broker binaries are standalone
(no Python / no pip on target). Sizes verified post-build via GitHub REST.
