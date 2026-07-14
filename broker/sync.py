"""Three-phase synchronized-start handshake (§9).

Flow (sync=true):
  controller --prepare--> broker --prepare--> group members
  each member --ready--> broker
  broker collects ready (all online members, or 2s timeout) then computes
  play_at = server_now + buffer_ms and broadcasts play_at to the group.

For sync=false the broker skips the handshake entirely and emits play_at=now
to the single target (handled in broker.py).

This module is the pure state machine: no sockets, no asyncio. broker.py owns
the timer and the actual fan-out; it calls into SyncSession/SyncManager.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set

DEFAULT_BUFFER_MS = 1500
DEFAULT_READY_TIMEOUT_MS = 2000


def server_now_ms() -> int:
    return int(time.time() * 1000)


def compute_play_at(now_ms: int, buffer_ms: int = DEFAULT_BUFFER_MS) -> int:
    """play_at on the broker master clock (§8.2 / §9.2)."""
    return now_ms + buffer_ms


@dataclass
class SyncSession:
    session_id: str
    group_id: str
    playlist_id: str
    push_id: str
    start_index: int
    seek_ms: int
    expected: Set[str]
    created_ms: int
    timeout_ms: int = DEFAULT_READY_TIMEOUT_MS
    ready: Set[str] = field(default_factory=set)
    done: bool = False

    def mark_ready(self, device_id: str) -> None:
        if device_id in self.expected:
            self.ready.add(device_id)

    def all_ready(self) -> bool:
        return bool(self.expected) and self.ready >= self.expected

    def deadline_ms(self) -> int:
        return self.created_ms + self.timeout_ms

    def is_expired(self, now_ms: int) -> bool:
        return now_ms >= self.deadline_ms()

    def ready_members(self) -> List[str]:
        """Members that actually reported ready (used at timeout: §9.2 says
        on timeout play_at goes to whoever is ready)."""
        return sorted(self.ready)


class SyncManager:
    """Tracks in-flight prepare sessions keyed by session_id."""

    def __init__(self, buffer_ms: int = DEFAULT_BUFFER_MS,
                 timeout_ms: int = DEFAULT_READY_TIMEOUT_MS):
        self.buffer_ms = buffer_ms
        self.timeout_ms = timeout_ms
        self._sessions: Dict[str, SyncSession] = {}
        # Index group_id -> active session_id for routing ready frames that
        # only carry playlist_id/device_id.
        self._by_group: Dict[str, str] = {}

    def start(self, session_id: str, group_id: str, playlist_id: str,
              expected: Set[str], *, push_id: str = "", start_index: int = 0, seek_ms: int = 0,
              now_ms: Optional[int] = None,
              timeout_ms: Optional[int] = None) -> SyncSession:
        now_ms = now_ms if now_ms is not None else server_now_ms()
        session = SyncSession(
            session_id=session_id,
            group_id=group_id,
            playlist_id=playlist_id,
            push_id=push_id,
            start_index=start_index,
            seek_ms=seek_ms,
            expected=set(expected),
            created_ms=now_ms,
            # §21.2 prefetch barrier: callers pass a longer timeout so players
            # have time to finish caching before we start whoever is ready.
            timeout_ms=timeout_ms if timeout_ms is not None else self.timeout_ms,
        )
        self._sessions[session_id] = session
        self._by_group[group_id] = session_id
        return session

    def cancel_group(self, group_id: str) -> None:
        sid = self._by_group.pop(group_id, None)
        if sid is not None:
            self._sessions.pop(sid, None)

    def find_for_group(self, group_id: str) -> Optional[SyncSession]:
        sid = self._by_group.get(group_id)
        if sid is None:
            return None
        return self._sessions.get(sid)

    def get(self, session_id: str) -> Optional[SyncSession]:
        return self._sessions.get(session_id)

    def on_ready(self, group_id: str, device_id: str) -> Optional[SyncSession]:
        """Record a ready and return the session if it just completed."""
        session = self.find_for_group(group_id)
        if session is None or session.done:
            return None
        session.mark_ready(device_id)
        if session.all_ready():
            session.done = True
            return session
        return None

    def complete(self, session: SyncSession,
                 now_ms: Optional[int] = None) -> int:
        """Finalize a session (all-ready or timeout) and return play_at."""
        now_ms = now_ms if now_ms is not None else server_now_ms()
        session.done = True
        self._sessions.pop(session.session_id, None)
        if self._by_group.get(session.group_id) == session.session_id:
            self._by_group.pop(session.group_id, None)
        return compute_play_at(now_ms, self.buffer_ms)

    def expired_sessions(self, now_ms: Optional[int] = None) -> List[SyncSession]:
        now_ms = now_ms if now_ms is not None else server_now_ms()
        return [s for s in self._sessions.values()
                if not s.done and s.is_expired(now_ms)]
