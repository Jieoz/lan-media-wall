"""Device registry, grouping, and persistence (§4, §5).

Holds the in-memory device table and mirrors the durable bits
(device_id <-> device_name <-> group_id <-> last_ip) to state.json so a broker
restart keeps group assignments and last-known IPs.
"""
from __future__ import annotations

import json
import os
import tempfile
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

DEFAULT_GROUP = "default"


def _now_ms() -> int:
    return int(time.time() * 1000)


@dataclass
class Device:
    device_id: str
    device_name: str = ""
    group_id: str = DEFAULT_GROUP
    last_ip: str = ""
    platform: str = ""
    app_version: str = ""
    screen: Dict[str, int] = field(default_factory=dict)
    capabilities: List[str] = field(default_factory=list)
    # Volatile runtime state (not persisted).
    online: bool = False
    last_status: Dict[str, Any] = field(default_factory=dict)
    last_seen: int = 0

    def persist_dict(self) -> Dict[str, Any]:
        return {
            "device_id": self.device_id,
            "device_name": self.device_name,
            "group_id": self.group_id,
            "last_ip": self.last_ip,
            "platform": self.platform,
            "app_version": self.app_version,
            "screen": self.screen,
            "capabilities": self.capabilities,
        }

    def wall_dict(self) -> Dict[str, Any]:
        """Status subset + last_seen for the §5.2 wall snapshot."""
        d = dict(self.last_status)
        d.update({
            "device_id": self.device_id,
            "device_name": self.device_name,
            "group_id": self.group_id,
            "last_ip": self.last_ip,
            "online": self.online,
            "last_seen": self.last_seen,
        })
        return d


class Registry:
    def __init__(self, state_path: str):
        self.state_path = state_path
        self._devices: Dict[str, Device] = {}
        # Explicit group metadata (name, sync, playlist_id) keyed by group_id.
        self._groups: Dict[str, Dict[str, Any]] = {}
        self._lock = threading.RLock()
        self._load()

    # ---- persistence -----------------------------------------------------
    def _load(self) -> None:
        if not os.path.exists(self.state_path):
            return
        try:
            with open(self.state_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return
        for d in data.get("devices", []):
            dev = Device(
                device_id=d["device_id"],
                device_name=d.get("device_name", ""),
                group_id=d.get("group_id", DEFAULT_GROUP),
                last_ip=d.get("last_ip", ""),
                platform=d.get("platform", ""),
                app_version=d.get("app_version", ""),
                screen=d.get("screen", {}),
                capabilities=d.get("capabilities", []),
            )
            self._devices[dev.device_id] = dev
        self._groups = data.get("groups", {})

    def _save_locked(self) -> None:
        data = {
            "devices": [d.persist_dict() for d in self._devices.values()],
            "groups": self._groups,
        }
        # Atomic write so a crash mid-write can't corrupt state.json.
        dir_ = os.path.dirname(os.path.abspath(self.state_path)) or "."
        fd, tmp = tempfile.mkstemp(dir=dir_, suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False, indent=2)
            os.replace(tmp, self.state_path)
        except OSError:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise

    def save(self) -> None:
        with self._lock:
            self._save_locked()

    # ---- device lifecycle ------------------------------------------------
    def register(self, device_id: str, *, device_name: str = "",
                 platform: str = "", app_version: str = "", ip: str = "",
                 screen: Optional[dict] = None,
                 capabilities: Optional[list] = None,
                 group_id: Optional[str] = None) -> Device:
        """Upsert a device on hello. Registry is authoritative for group_id:
        an existing assignment is kept unless the device is brand new."""
        with self._lock:
            dev = self._devices.get(device_id)
            if dev is None:
                dev = Device(
                    device_id=device_id,
                    group_id=group_id or DEFAULT_GROUP,
                )
                self._devices[device_id] = dev
            if device_name:
                dev.device_name = device_name
            if platform:
                dev.platform = platform
            if app_version:
                dev.app_version = app_version
            if ip:
                dev.last_ip = ip
            if screen:
                dev.screen = screen
            if capabilities is not None:
                dev.capabilities = capabilities
            dev.online = True
            dev.last_seen = _now_ms()
            self._save_locked()
            return dev

    def set_offline(self, device_id: str) -> None:
        with self._lock:
            dev = self._devices.get(device_id)
            if dev:
                dev.online = False
                dev.last_seen = _now_ms()

    def update_status(self, device_id: str, status: Dict[str, Any]) -> None:
        with self._lock:
            dev = self._devices.get(device_id)
            if dev is None:
                dev = Device(device_id=device_id)
                self._devices[device_id] = dev
            dev.last_status = status
            dev.online = bool(status.get("online", True))
            dev.last_seen = _now_ms()
            grp = status.get("group_id")
            if grp and grp != dev.group_id:
                # Trust device-reported group only if we have nothing better.
                pass

    def assign_group(self, device_id: str, group_id: str) -> bool:
        with self._lock:
            dev = self._devices.get(device_id)
            if dev is None:
                return False
            dev.group_id = group_id
            self._save_locked()
            return True

    # ---- queries ---------------------------------------------------------
    def get(self, device_id: str) -> Optional[Device]:
        with self._lock:
            return self._devices.get(device_id)

    def all_devices(self) -> List[Device]:
        with self._lock:
            return list(self._devices.values())

    def members(self, group_id: str, *, online_only: bool = False) -> List[str]:
        with self._lock:
            return [
                d.device_id for d in self._devices.values()
                if d.group_id == group_id and (not online_only or d.online)
            ]

    def set_group_meta(self, group_id: str, **kv: Any) -> None:
        with self._lock:
            meta = self._groups.setdefault(group_id, {})
            meta.update({k: v for k, v in kv.items() if v is not None})
            self._save_locked()

    def groups_snapshot(self) -> List[Dict[str, Any]]:
        """Build the §5.2 groups array from current membership + meta."""
        with self._lock:
            seen = {d.group_id for d in self._devices.values()}
            seen.update(self._groups.keys())
            out = []
            for gid in sorted(seen):
                meta = self._groups.get(gid, {})
                out.append({
                    "group_id": gid,
                    "name": meta.get("name", gid),
                    "sync": meta.get("sync", True),
                    "playlist_id": meta.get("playlist_id"),
                    "members": [
                        d.device_id for d in self._devices.values()
                        if d.group_id == gid
                    ],
                })
            return out
