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

    def consume(self, value: T) -> None:
        """Keep lap bookkeeping honest when the queue advanced by other means
        (sequential order, or a ``prev`` that walked back into history)."""
        if value in self._remaining:
            self._remaining.remove(value)
        self._last = value


class MusicQueue:
    """§6.3c music ordering: the single authority for "which track plays next".

    Two orderings behind one interface, because toggling shuffle must not fork
    the playback path:
      - shuffle on  -> ShuffleBag laps (each track once per lap, no lap-boundary repeat)
      - shuffle off -> the controller's list order, wrapping at the end

    ``prev`` is a real back-button: it walks the bounded play HISTORY so the user
    hears the track they just heard, rather than another random one (which reads
    as a broken button). History is capped at ``MAX_HISTORY`` so a box left
    playing for weeks cannot grow it without bound.

    Mirrors ``MusicQueue`` in the Android player; the two must stay behaviourally
    identical (same wire contract, §6.3c).
    """

    MAX_HISTORY = 32

    def __init__(self, rng: Optional[random.Random] = None) -> None:
        self._bag: ShuffleBag[str] = ShuffleBag(rng)
        self._history: list[str] = []
        self.shuffle = True
        self.current: Optional[str] = None

    @property
    def cycle(self) -> int:
        return self._bag.cycle

    @property
    def history_depth(self) -> int:
        return len(self._history)

    def set_shuffle(self, enabled: bool) -> bool:
        """Returns True when the ordering actually changed."""
        if self.shuffle == enabled:
            return False
        self.shuffle = enabled
        # Laps belong to the shuffled ordering only; a stale bag would make the
        # first lap after re-enabling shuffle skip tracks.
        self._bag.reset()
        return True

    def reset(self) -> None:
        self._bag.reset()
        self._history = []
        self.current = None

    def next(self, candidates: Sequence[str]) -> Optional[str]:
        if not candidates:
            self.current = None
            return None
        if self.current is not None:
            self._push_history(self.current)
        if self.shuffle:
            picked = self._bag.next(candidates)
        else:
            picked = self._sequential(1, candidates)
            if picked is not None:
                self._bag.consume(picked)
        self.current = picked
        return picked

    def prev(self, candidates: Sequence[str]) -> Optional[str]:
        if not candidates:
            self.current = None
            return None
        from_history = self._pop_history(candidates)
        if from_history is not None:
            picked = from_history
        elif not self.shuffle:
            # Sequential order has a well-defined "one before this"; shuffle
            # does not, so with no history it holds the current track.
            picked = self._sequential(-1, candidates)
        elif self.current is not None and self.current in candidates:
            picked = self.current
        else:
            picked = candidates[0]
        self._bag.consume(picked)
        self.current = picked
        return picked

    def adopt(self, item_id: Optional[str]) -> None:
        """Re-seat the queue on a known current track (restart / snapshot restore)."""
        self.current = item_id
        if item_id is not None:
            self._bag.consume(item_id)

    def _sequential(self, delta: int, candidates: Sequence[str]) -> str:
        try:
            at = candidates.index(self.current)  # type: ignore[arg-type]
        except ValueError:
            return candidates[0] if delta >= 0 else candidates[-1]
        return candidates[(at + delta) % len(candidates)]

    def _push_history(self, item_id: str) -> None:
        self._history.append(item_id)
        while len(self._history) > self.MAX_HISTORY:
            self._history.pop(0)

    def _pop_history(self, candidates: Sequence[str]) -> Optional[str]:
        """Discard history entries the current list no longer contains."""
        while self._history:
            candidate = self._history.pop()
            if candidate in candidates:
                return candidate
        return None


@dataclass(frozen=True)
class MusicPlaylist:
    playlist_id: str
    revision: int
    items: list[dict]
    # §6.3c: playback ordering travels with the list it orders. Absent (old
    # controllers) means shuffle, which is the pre-v1.19.7 behaviour.
    shuffle: bool = True

    @classmethod
    def from_payload(cls, payload: object) -> Optional["MusicPlaylist"]:
        if not isinstance(payload, dict):
            return None
        playlist_id = payload.get("playlist_id")
        revision = payload.get("revision")
        raw_items = payload.get("items")
        raw_shuffle = payload.get("shuffle", True)
        if not isinstance(playlist_id, str) or not playlist_id.strip():
            return None
        if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
            return None
        if not isinstance(raw_items, list):
            return None
        if not isinstance(raw_shuffle, bool):
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
        return cls(playlist_id.strip(), revision, items, raw_shuffle)
