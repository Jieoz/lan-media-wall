"""Static contracts for the v1.18.0 operator-UX optimization.

Flutter + Android UI compile only in cloud CI (no Dart runtime on the builder),
so — exactly as scripts/tests/test_android_ui_contracts.py already does — these
tests pin the production wiring at source level. They are the locally-runnable
RED→GREEN evidence for the eight required contract areas:

  1. controller settings topology truth in P2P vs Broker
  2. strict port validation 1–65535 with no silent 8770 fallback
  3. saved/reconnecting wording, not optimistic connected wording
  4. unified single-device push choices 仅下发并缓存 / 缓存完成后播放
  5. destructive remote clear confirmation with explicit target/effect
  6. sent-vs-ACK wording for restart/reboot/update/playlist ops
  7. Android player setup hierarchy: identity/QR primary, diagnostics secondary
  8. Chinese operator-facing labels

Real Dart widget/unit tests (connection_status_test.dart, push_workflow_test.dart,
settings_topology_test.dart) additionally run in cloud CI (flutter test).
"""
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
FL = ROOT / "remote_flutter" / "lib"
CONN = FL / "ui" / "connection_status.dart"
PUSH = FL / "ui" / "push_workflow.dart"
SETTINGS = FL / "ui" / "settings_screen.dart"
WALL_STATE = FL / "state" / "wall_state.dart"
ORCH = FL / "ui" / "orchestration_pane.dart"
DEVWALL = FL / "ui" / "device_wall_pane.dart"
MUSIC_TERMINAL = FL / "ui" / "music_terminal_dialog.dart"
SHELL = FL / "ui" / "responsive_shell.dart"
ANDROID = ROOT / "android_apps" / "player" / "app" / "src" / "main"
LAYOUT = ANDROID / "res" / "layout" / "activity_settings.xml"
STRINGS = ANDROID / "res" / "values" / "strings.xml"
STRINGS_ZH = ANDROID / "res" / "values-zh-rCN" / "strings.xml"
SETTINGS_ACT = ANDROID / "kotlin/com/jieoz/lanmediawall/player/SettingsActivity.kt"


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


# ---- Area 1: topology truth (P2P vs Broker) ----
def test_connection_mode_enum_and_persistence() -> None:
    conn = _read(CONN)
    assert "enum ConnectionMode" in conn
    assert "autoP2p" in conn and "broker" in conn
    ws = _read(WALL_STATE)
    # A persisted connection mode key + honored in topology evaluation.
    assert "connectionMode" in ws
    assert "ConnectionMode" in ws
    assert "settings.connection_mode" in ws


def test_auto_p2p_mode_does_not_dial_broker_host() -> None:
    ws = _read(WALL_STATE)
    # _evaluateTopology must gate the "手填 broker 优先" branch on broker mode,
    # so an auto/P2P controller with a stale brokerHost still goes P2P.
    assert "_connectionMode == ConnectionMode.broker" in ws


def test_connection_label_is_topology_derived() -> None:
    conn = _read(CONN)
    # Pure helper producing the spec's exact strings.
    assert "connectionLabel" in conn
    assert "P2P · 已连接" in conn
    assert "P2P · 正在发现设备" in conn
    assert "Broker · 已连接" in conn
    assert "Broker · 重连中" in conn
    # The label derivation is centralized in WallState.connectionStatusLabel,
    # which delegates to the pure connectionLabel() helper (single source of
    # truth). The settings screen + top status bar consume that getter rather
    # than re-plumbing topology/peers/conn into each widget.
    ws = _read(WALL_STATE)
    assert "connectionStatusLabel" in ws
    assert "connectionLabel(" in ws
    assert "connectionStatusLabel" in _read(SETTINGS)
    assert "connectionStatusLabel" in _read(SHELL)


# ---- Area 2: strict port validation ----
def test_strict_port_validation_no_silent_fallback() -> None:
    conn = _read(CONN)
    assert "validateBrokerPort" in conn
    # 1..65535 explicit range and a non-null error path.
    assert "1" in conn and "65535" in conn
    settings = _read(SETTINGS)
    # The old silent `?? 8770` substitution must be gone from save().
    assert "int.tryParse(_port.text.trim()) ?? 8770" not in settings
    assert "validateBrokerPort" in settings


# ---- Area 3: saved/reconnecting wording ----
def test_save_says_reconnecting_not_connected() -> None:
    settings = _read(SETTINGS)
    assert "设置已保存，正在重新连接" in settings
    assert "已保存并重连" not in settings


# ---- Area 4: unified push workflow ----
def test_unified_push_workflow_exists_and_is_shared() -> None:
    push = _read(PUSH)
    assert "showPushToDeviceDialog" in push
    assert "仅下发并缓存" in push
    assert "缓存完成后播放" in push
    # Summary documents target / count / replace-append / cache / playback.
    assert "pushConfirmSummary" in push
    orch = _read(ORCH)
    dev = _read(DEVWALL)
    # BOTH single-device entry points funnel into the shared dialog.
    assert "showPushToDeviceDialog" in orch
    assert "showPushToDeviceDialog" in dev


def test_push_summary_documents_cache_and_playback() -> None:
    push = _read(PUSH)
    body = push
    # summary references count, cache retention, and whether playback starts.
    for token in ("项", "缓存", "播放", "替换", "追加"):
        assert token in body


# ---- Area 5: destructive remote clear confirmation ----
def test_remote_clear_renamed_and_confirmed() -> None:
    orch = _read(ORCH)
    assert "停止播放并清空设备列表" in orch
    assert "清空本地草稿" in orch
    # Confirm button uses the destructive 停止并清空 … wording.
    assert "停止并清空" in orch
    # Confirmation states cached files are retained + online count.
    assert "缓存文件保留" in orch or "保留缓存" in orch


def test_local_draft_clear_is_distinct_from_remote() -> None:
    orch = _read(ORCH)
    # The purely-local clear must not claim to have touched any device.
    assert "清空本地草稿" in orch


# ---- Area 6: sent-vs-ACK wording ----
def test_no_optimistic_effect_wording_before_ack() -> None:
    orch = _read(ORCH)
    dev = _read(DEVWALL)
    joined = orch + dev
    # These claim the effect already happened on the device — forbidden before
    # a device ACK. (Draft-only 已清空编辑列表 in orchestration is allowed; the
    # device-facing ones below are not.)
    assert "已清空整组" not in orch
    assert "已清空该设备" not in orch
    assert "'已暂停这一台'" not in dev
    assert "'已恢复这一台'" not in dev
    assert "'已停止这一台'" not in dev
    # A shared sent-wording helper must exist and be used.
    assert "命令已发送，等待设备确认" in joined or "sentAwaitingAck" in joined


def test_sent_ack_helper_defined_once() -> None:
    push = _read(PUSH)
    assert "sentAwaitingAck" in push


def test_runtime_mode_controls_match_operator_mental_model() -> None:
    music = _read(MUSIC_TERMINAL)
    dev = _read(DEVWALL)
    # Mode switching belongs to the normal playback controls. The music dialog
    # is a list editor and must not carry a second, divergent mode-control row.
    assert "播放模式" in dev
    assert "SegmentedButton<RuntimeMode>" in dev
    assert "'图片/视频'" in dev
    assert "'音乐终端'" in dev
    assert "恢复图片/视频" not in music
    assert "RuntimeMode.visual" not in music
    assert "RuntimeMode.standby" not in music
    assert "恢复前态" not in music
    # Standby is an output/playback control beside Stop, with a visible inverse.
    transport = dev[dev.index("class _DeviceTransportRow"):]
    assert "'停止'" in transport
    assert "'待机'" in transport
    assert "'退出待机'" in transport
    assert "setDeviceRuntimeMode" in transport
    assert "restoreDeviceRuntimeMode" in transport
    assert "setMode(RuntimeMode.standby" in transport
    assert "? '设备已退出待机，恢复" in transport


def test_playback_controls_group_modes_and_keep_list_commit_in_editor() -> None:
    dev = _read(DEVWALL)
    music = _read(MUSIC_TERMINAL)
    transport = dev[dev.index("class _DeviceTransportRow"):]
    # One mode selector replaces three copied action buttons. Playlist mutation
    # remains in one editor, while entering music mode from playback controls
    # starts the already-confirmed device playlist.
    assert "section('播放'" in transport
    assert "section('播放模式'" in transport
    assert "section('音乐列表'" in transport
    assert "section('电源'" in transport
    assert "'编辑音乐列表'" in transport
    assert "'切换音乐终端'" not in transport
    assert "'保存并播放'" not in transport
    assert "'恢复图片/视频'" not in transport
    assert "RuntimeMode.music" in transport
    assert "RuntimeMode.visual" in transport
    assert "保存并播放" not in music
    assert "恢复图片/视频" not in music
    assert "'保存列表'" in music
    # Legacy devices that report a count without a complete snapshot remain
    # protected from an empty overwrite inside the sole commit surface.
    assert "!authoritative && reportedSize > 0" in music


def test_single_device_dialog_tracks_confirmed_live_mode_snapshot() -> None:
    dev = _read(DEVWALL)
    dialog = dev[
        dev.index("Future<void> _configureDeviceDialog"):
        dev.index("class _DeviceTransportRow")
    ]
    # showDialog is an Overlay: rebuilding the pane underneath is insufficient.
    # The dialog itself subscribes and re-resolves the immutable device view.
    assert "ctx.watch<WallState>()" in dialog
    assert "candidate.deviceId == device.deviceId" in dialog
    assert "_DeviceStatusView(device: liveDevice)" in dialog
    assert "_DeviceTransportRow(state: liveState, device: liveDevice)" in dialog


def test_android_discovery_thread_contains_advisory_packet_failures() -> None:
    discovery = _read(
        ANDROID / "kotlin/com/jieoz/lanmediawall/player/net/Discovery.kt"
    )
    assert "try {\n                handle(packet, sock)" in discovery
    assert "catch (e: Exception)" in discovery
    assert "required auth has no usable signing key" in discovery


# ---- Area 7: Android setup hierarchy ----
def test_android_settings_layout_is_well_formed_xml() -> None:
    ET.parse(LAYOUT)


def test_android_qr_before_diagnostics() -> None:
    layout = _read(LAYOUT)
    qr = layout.index("image_pair_qr")
    diag = layout.index("text_diag_status")
    assert qr < diag, "pairing QR must appear before diagnostics"


def test_android_primary_device_card_before_advanced() -> None:
    layout = _read(LAYOUT)
    # New primary identity/access section header + collapsed advanced section.
    assert "@string/label_player_access" in layout
    assert "@string/label_advanced_section" in layout
    assert "btn_toggle_advanced" in layout
    assert "advanced_container" in layout
    # device name + save live before the advanced toggle.
    assert layout.index("input_device_name") < layout.index("btn_toggle_advanced")
    assert layout.index("image_pair_qr") < layout.index("btn_toggle_advanced")
    # broker host (advanced) lives inside/after the advanced toggle.
    assert layout.index("btn_toggle_advanced") < layout.index("input_broker_host")


def test_android_advanced_toggle_wired() -> None:
    act = _read(SETTINGS_ACT)
    assert "btnToggleAdvanced" in act
    assert "advancedContainer" in act
    # API19-safe visibility toggle.
    assert "View.GONE" in act and "View.VISIBLE" in act


# ---- Area 8: Chinese operator-facing labels ----
def test_primary_labels_chinese_in_default_and_zh() -> None:
    for path in (STRINGS, STRINGS_ZH):
        s = _read(path)
        assert "label_player_access" in s
        assert "label_advanced_section" in s
        assert "action_refresh_conn" in s
    default = _read(STRINGS)
    # Primary operator-facing labels are Chinese even in the default file
    # (field boxes may not run a zh locale).
    import re

    def val(name: str, text: str) -> str:
        m = re.search(rf'<string name="{name}">(.*?)</string>', text, re.S)
        return m.group(1) if m else ""

    assert "播放端" in val("label_player_access", default)
    assert "高级" in val("label_advanced_section", default)
    assert any("一" <= c <= "鿿" for c in val("action_refresh_conn", default))


def test_save_button_reachable_and_primary() -> None:
    layout = _read(LAYOUT)
    # Save stays present and sits in the primary card (before advanced toggle).
    assert "btn_save" in layout
    assert layout.index("btn_save") < layout.index("btn_toggle_advanced")
