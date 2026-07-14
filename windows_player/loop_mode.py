"""§6.3 LoopMode — single-source three-mode loop semantics + one legacy fold.

Wire contract (protocol_spec §6.3b): a `playlist` payload carries the canonical
string field ``loop_mode`` in {"none","all","one"}. Legacy clients (≤v1.14.13)
only send the boolean ``loop``. The ONE fold point below resolves both into a
:class:`LoopMode`:

  - ``loop_mode`` present & valid  -> that mode (canonical, always wins)
  - ``loop_mode`` absent/unknown   -> derive from legacy ``loop``:
                                      true -> ALL, false/absent -> NONE

Senders emit BOTH fields during the compatibility window: ``loop_mode``
(canonical) plus ``loop = (mode != NONE)``, so an un-upgraded player still wraps
a playlist that is meant to loop (ONE degrades to ALL on old players — a
harmless widening, never worse than today).

Behaviour keyed off the resolved mode (identical across Windows/Android/Flutter):
  - NONE : playback stops/holds at completion; explicit prev/next clamps at ends.
  - ALL  : completion and prev/next wrap around the whole list.
  - ONE  : the current item repeats seamlessly on completion; an explicit
           prev/next still navigates (with wrap).
"""
from enum import Enum
from typing import Any, Dict


class LoopMode(str, Enum):
    NONE = "none"
    ALL = "all"
    ONE = "one"


def resolve_loop_mode(payload: Dict[str, Any]) -> LoopMode:
    """The single legacy fold point. Prefer canonical ``loop_mode``; else derive
    from the legacy boolean ``loop``."""
    raw = payload.get("loop_mode") if payload else None
    if isinstance(raw, str):
        try:
            return LoopMode(raw.strip().lower())
        except ValueError:
            pass  # unknown string -> fall through to legacy fold
    return LoopMode.ALL if bool((payload or {}).get("loop", False)) else LoopMode.NONE


def legacy_loop_bool(mode: LoopMode) -> bool:
    """Compat projection emitted alongside ``loop_mode`` so old players still
    wrap a looping list."""
    return mode != LoopMode.NONE
