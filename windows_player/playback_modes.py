"""Pure Player runtime-mode and shuffle-bag contracts."""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import random
from typing import Generic, Optional, Sequence, TypeVar


class PlaybackMode(str, Enum):
    VISUAL = "visual"
    MUSIC = "music"
    STANDBY = "standby"

    @classmethod
    def parse(cls, raw: object) -> Optional["PlaybackMode"]:
        try:
            return cls(str(raw))
        except ValueError:
            return None


class PlaybackModeState:
    def __init__(
        self,
        current: PlaybackMode = PlaybackMode.VISUAL,
        previous_active: PlaybackMode = PlaybackMode.VISUAL,
    ) -> None:
        self.current = current
        self.previous_active = previous_active

    def set_mode(self, mode: PlaybackMode) -> PlaybackMode:
        self.current = mode
        if mode is not PlaybackMode.STANDBY:
            self.previous_active = mode
        return self.current

    def restore(self) -> PlaybackMode:
        target = self.previous_active
        if target is PlaybackMode.STANDBY:
            target = PlaybackMode.VISUAL
        return self.set_mode(target)


T = TypeVar("T")


class ShuffleBag(Generic[T]):
    """Emit every distinct item once per shuffled lap without boundary repeat."""

    def __init__(self, rng: Optional[random.Random] = None) -> None:
        self._rng = rng or random.Random()
        self._universe: list[T] = []
        self._remaining: list[T] = []
        self._last: Optional[T] = None
        self.cycle = 0

    def next(self, items: Sequence[T]) -> Optional[T]:
        distinct = list(dict.fromkeys(items))
        if not distinct:
            self._universe = []
            self._remaining = []
            return None
        if distinct != self._universe:
            self._universe = distinct
            self._remaining = []
        if not self._remaining:
            self.cycle += 1
            self._remaining = list(self._universe)
            self._rng.shuffle(self._remaining)
            if len(self._remaining) > 1 and self._remaining[0] == self._last:
                swap = next(i for i, value in enumerate(self._remaining) if value != self._last)
                self._remaining[0], self._remaining[swap] = (
                    self._remaining[swap], self._remaining[0])
        value = self._remaining.pop(0)
        self._last = value
        return value

    def reset(self) -> None:
        self._universe = []
        self._remaining = []
        self._last = None
        self.cycle = 0


@dataclass(frozen=True)
class MusicPlaylist:
    playlist_id: str
    revision: int
    items: list[dict]

    @classmethod
    def from_payload(cls, payload: object) -> Optional["MusicPlaylist"]:
        if not isinstance(payload, dict):
            return None
        playlist_id = payload.get("playlist_id")
        revision = payload.get("revision")
        raw_items = payload.get("items")
        if not isinstance(playlist_id, str) or not playlist_id.strip():
            return None
        if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
            return None
        if not isinstance(raw_items, list):
            return None
        items: list[dict] = []
        for item in raw_items:
            if not isinstance(item, dict):
                return None
            if item.get("type") != "audio":
                return None
            if not isinstance(item.get("item_id"), str) or not item["item_id"]:
                return None
            if not isinstance(item.get("url"), str) or not item["url"]:
                return None
            items.append(dict(item))
        return cls(playlist_id.strip(), revision, items)
