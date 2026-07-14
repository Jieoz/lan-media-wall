"""Static contracts for Android UI paths generated/built only in cloud CI.

These tests intentionally pin the production wiring, not just helper behavior:
- player diagnostics must offer Android's document picker and write its payload to
  the operator-selected Uri;
- controller cold/process recreation must discard saved Android state before
  Flutter can restore a transient settings route.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLAYER_ACTIVITY = ROOT / "android_apps/player/app/src/main/kotlin/com/jieoz/lanmediawall/player/SettingsActivity.kt"
CONTROLLER_ACTIVITY = ROOT / "remote_flutter/android_template/MainActivity.kt"
FLUTTER_WORKFLOW = ROOT / ".github/workflows/flutter-build.yml"


def test_player_diagnostics_uses_create_document_picker_and_selected_uri() -> None:
    source = PLAYER_ACTIVITY.read_text(encoding="utf-8")
    assert "Intent.ACTION_CREATE_DOCUMENT" in source
    assert 'setType("text/plain")' in source
    assert "startActivityForResult" in source
    assert "contentResolver.openOutputStream" in source
    assert "DIAGNOSTIC_EXPORT_REQUEST" in source
    assert "exportDiagnosticsToFallbackFile" in source
    assert "getExternalFilesDir(null) ?: filesDir" in source


def test_controller_cold_start_discards_android_saved_state_before_flutter() -> None:
    source = CONTROLLER_ACTIVITY.read_text(encoding="utf-8")
    assert "override fun shouldRestoreAndSaveState(): Boolean = false" in source
    assert "override fun onCreate(savedInstanceState: Bundle?)" in source
    assert "super.onCreate(null)" in source


def test_cloud_build_installs_repository_owned_controller_activity() -> None:
    workflow = FLUTTER_WORKFLOW.read_text(encoding="utf-8")
    assert 'SOURCE="remote_flutter/android_template/MainActivity.kt"' in workflow
    assert 'cmp --silent "$SOURCE" "$TARGET"' in workflow
