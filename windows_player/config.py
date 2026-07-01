"""Configuration loading + persistent local state.

config.py role: read config.yaml (path from arg/env), apply env overrides
(LMW_PSK takes precedence over the file so the secret can stay out of the
file), and expose a typed Config. Persistent runtime state (device_id,
device_name, group_id, last_task) lives in a small JSON file under the cache
dir so it survives reboots — see §4 (device_id persistent, device_name
first-boot settable + persisted) and §10 resume_last.
"""

from __future__ import annotations

import json
import os
import socket
import threading
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

try:
    import yaml  # PyYAML
except Exception:  # pragma: no cover - yaml is a hard dep, guard for import-time
    yaml = None  # type: ignore


DEFAULTS: Dict[str, Any] = {
    "broker": {"host": "127.0.0.1", "port": 8770, "use_wss": False, "wss_port": 8771},
    "psk": "CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY",
    "auth_mode": "open",                      # §13: open|optional|required (open=default)
    "key_mode": "global",                     # §17.3: global(v1.2)|derived(v1.3)
    # §17.4 per-end key material from §15 pairing (derived mode, zero-PSK end).
    # device_key/broker_key are hex; identity is our `from`. Empty = not paired
    # in derived mode (we use the global psk instead). Users never hand-fill
    # these — they arrive via the pairing QR. Kept out of the yaml by default.
    "derived_key": {"device_key": None, "identity": None, "broker_key": None},
    "topology": {"cohost": False,             # §14.2: True → also run broker in-process
                 "discover_timeout_s": 3.0,   # §14.5: wait this long for a broker before p2p
                 "p2p_listen_port": 8770,      # §14.3: p2p server port
                 "auto": True},                # §14.5: auto-pick role from discovery
    "device": {"name": None, "group_id": "default"},
    "cache_dir": "./cache",
    "state_dir": "./state",
    "mpv": {
        "path": "mpv",                       # mpv.exe shipped alongside on Windows
        "ipc_pipe": r"\\.\pipe\lmw-mpv",     # Windows named pipe
        "ipc_socket": "/tmp/lmw-mpv.sock",   # POSIX fallback (dev/CI)
        # §9/§11: hardware decoding. auto-safe = let mpv pick only vetted HW
        # decoders (no known green/tear fallbacks) so low-end boxes stop
        # CPU-soft-decoding. Set "no" to disable when diagnosing green/garbled
        # video, or pin a specific decoder (e.g. "d3d11va"). Survives restarts.
        "hwdec": "auto-safe",
        "extra_args": [],
    },
    "idle_image": None,                       # path to placeholder; None = pure black
    "thumbnail": {"enabled": True, "interval_s": 5, "max_width": 320, "jpeg_quality": 70,
                  "always_collect": False},   # always_collect: ignore controller-presence gate
    "discovery": {"enabled": True, "udp_port": 8772},
    "status_interval_s": 1.5,                 # §5: every 1–2s
    "time_sync_interval_s": 30,               # §8.1
    "watchdog": {"check_interval_s": 1.0, "restart_grace_s": 5.0},
}


def _deep_merge(base: Dict[str, Any], over: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(base)
    for k, v in over.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def _hex_to_bytes(hexkey: Any) -> Optional[bytes]:
    """Decode a hex key string to raw bytes, or None if absent/malformed.

    §17 device/broker keys travel as hex in config/QR; the HMAC layer needs the
    raw bytes. Malformed hex degrades to None (fall back to the psk path) rather
    than raising — a bad QR must never crash the player."""
    if not isinstance(hexkey, str) or not hexkey.strip():
        return None
    try:
        return bytes.fromhex(hexkey.strip())
    except ValueError:
        return None


@dataclass
class Config:
    raw: Dict[str, Any]
    path: Optional[Path] = None

    # convenience typed accessors --------------------------------------
    @property
    def psk(self) -> str:
        # env wins over file (keep secret out of the yaml in prod)
        return os.environ.get("LMW_PSK", self.raw["psk"])

    @property
    def broker_url(self) -> str:
        b = self.raw["broker"]
        if b.get("use_wss"):
            return f"wss://{b['host']}:{b.get('wss_port', 8771)}"
        return f"ws://{b['host']}:{b.get('port', 8770)}"

    @property
    def auth_mode(self) -> str:
        """§13 auth mode. env LMW_AUTH_MODE wins over file/default, mirroring
        the PSK override so a deployment can flip modes without editing yaml."""
        return os.environ.get("LMW_AUTH_MODE", self.raw.get("auth_mode", "open"))

    @property
    def key_mode(self) -> str:
        """§17.3 key mode. env LMW_KEY_MODE wins over file/default. Coordinator
        announcements still override this at runtime via AuthState.adopt_key_mode
        — this is only the *starting* mode before we hear from a coordinator."""
        return os.environ.get("LMW_KEY_MODE", self.raw.get("key_mode", "global"))

    @property
    def device_key(self) -> Optional[bytes]:
        """§17.4 this end's own device_key (raw 32 bytes) from pairing, or None.

        Stored as hex in config/state; decoded here. env LMW_DEVICE_KEY (hex)
        wins, mirroring the PSK override. Invalid hex → None (we then fall back
        to the global psk path rather than crashing)."""
        hexkey = os.environ.get("LMW_DEVICE_KEY") or \
            self.get("derived_key", "device_key")
        return _hex_to_bytes(hexkey)

    @property
    def identity(self) -> Optional[str]:
        """§17.4 our paired identity (the `from` we sign as), or None to let the
        caller default it to `player:<device_id>`."""
        ident = self.get("derived_key", "identity")
        return ident if isinstance(ident, str) and ident else None

    @property
    def broker_key(self) -> Optional[bytes]:
        """§17.4 broker verify key (raw bytes) from pairing, for verifying
        inbound broker frames without holding the PSK. None if not paired."""
        hexkey = os.environ.get("LMW_BROKER_KEY") or \
            self.get("derived_key", "broker_key")
        return _hex_to_bytes(hexkey)

    @property
    def cache_dir(self) -> Path:
        return Path(self.raw["cache_dir"]).expanduser()

    @property
    def state_dir(self) -> Path:
        return Path(self.raw["state_dir"]).expanduser()

    def get(self, *keys: str, default: Any = None) -> Any:
        node: Any = self.raw
        for k in keys:
            if not isinstance(node, dict) or k not in node:
                return default
            node = node[k]
        return node


def load_config(path: Optional[str] = None) -> Config:
    """Load config.yaml merged over DEFAULTS. Missing file → defaults only
    (with env LMW_PSK still applied via Config.psk)."""
    cfg_path = path or os.environ.get("LMW_CONFIG")
    raw = dict(DEFAULTS)
    resolved: Optional[Path] = None
    if cfg_path:
        p = Path(cfg_path).expanduser()
        if p.exists():
            if yaml is None:
                raise RuntimeError("PyYAML not installed but config file given")
            with p.open("r", encoding="utf-8") as f:
                loaded = yaml.safe_load(f) or {}
            raw = _deep_merge(DEFAULTS, loaded)
            resolved = p
    return Config(raw=raw, path=resolved)


def apply_pairing(cfg: Config, overlay: Dict[str, Any]) -> Config:
    """Deep-merge a pairing overlay (from pairing.pairing_to_config_overlay)
    onto a loaded Config, in place. Returns the same Config for chaining.

    Lets a `lmw://pair?...` string (§15) override broker host/port/wss, psk,
    auth_mode, and device group/name without editing config.yaml."""
    cfg.raw = _deep_merge(cfg.raw, overlay)
    return cfg


def detect_ip(broker_host: str = "8.8.8.8") -> str:
    """Best-effort primary LAN IP (the route the broker would be reached on)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((broker_host, 80))
        return s.getsockname()[0]
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "127.0.0.1"
    finally:
        s.close()


@dataclass
class PersistentState:
    """Small JSON store for device identity + last task (resume_last)."""

    path: Path
    data: Dict[str, Any] = field(default_factory=dict)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    @classmethod
    def load(cls, state_dir: Path) -> "PersistentState":
        state_dir.mkdir(parents=True, exist_ok=True)
        p = state_dir / "state.json"
        data: Dict[str, Any] = {}
        if p.exists():
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
            except Exception:
                data = {}
        st = cls(path=p, data=data)
        # device_id is generated once and persisted forever (§4)
        if not st.data.get("device_id"):
            st.data["device_id"] = "win-" + uuid.uuid4().hex[:10]
            st.save()
        return st

    def save(self) -> None:
        with self._lock:
            tmp = self.path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=2),
                           encoding="utf-8")
            tmp.replace(self.path)  # atomic on same fs

    # accessors --------------------------------------------------------
    @property
    def device_id(self) -> str:
        return self.data["device_id"]

    def device_name(self, fallback: Optional[str]) -> str:
        name = self.data.get("device_name")
        if name:
            return name
        # first boot: settable from config, else derive from id, then persist
        name = fallback or self.data["device_id"]
        self.data["device_name"] = name
        self.save()
        return name

    def set_device_name(self, name: str) -> None:
        self.data["device_name"] = name
        self.save()

    @property
    def group_id(self) -> str:
        return self.data.get("group_id", "default")

    def set_group_id(self, group_id: str) -> None:
        self.data["group_id"] = group_id
        self.save()

    @property
    def last_task(self) -> Optional[Dict[str, Any]]:
        return self.data.get("last_task")

    def set_last_task(self, task: Optional[Dict[str, Any]]) -> None:
        self.data["last_task"] = task
        self.save()

    @property
    def playlists(self) -> Dict[str, Any]:
        return self.data.setdefault("playlists", {})

    def store_playlist(self, playlist: Dict[str, Any]) -> None:
        pid = playlist.get("playlist_id")
        if pid:
            self.playlists[pid] = playlist
            self.save()
