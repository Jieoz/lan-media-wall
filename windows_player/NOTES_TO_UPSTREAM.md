# NOTES_TO_UPSTREAM — Windows player

Non-blocking protocol questions / ambiguities found while implementing the
player against `protocol_spec.md` v1. **None blocked implementation** — for each
I picked the safest reversible default (noted below) and kept using the v1
protocol as written. No spec fields were changed.

## 1. No explicit "controller present" signal for the thumbnail gate (§6.4)
§6.4 says thumbnails are collected/sent "仅当至少一个 controller 在线时" (only
when ≥1 controller is online), but the spec defines no broker→player message
telling the player that a controller is present. The player can't observe the
controller roster directly (controllers only talk to the broker).

**Default chosen:** a config flag `thumbnail.always_collect` (default `false`)
plus an internal `controller_present` flag. Until the broker provides a signal,
set `always_collect: true` on devices that should always feed the wall.
**Suggested fix:** broker pushes a lightweight `controller_presence`
(`payload:{present:bool}`) or includes a `controllers_online:int` field in
`welcome`/a periodic broker→player nudge so players can gate precisely.

## 2. `time_sync_ack` correlation field (§8.1)
§8.1 shows `time_sync_ack.payload` as `{t1(echo), t2, t3}`. Correlating a reply
to the originating request relies on the echoed `t1`. If a player has multiple
in-flight syncs with identical `t1` (same-ms), echo-only correlation is
ambiguous.

**Default chosen:** the player also remembers `msg_id → t1` and, if the ack's
payload happens to carry the request `msg_id`, prefers that mapping; otherwise
it falls back to the echoed `t1`. This is backward compatible (extra lookup
only used if present).
**Suggested fix:** have the broker echo the original `msg_id` in
`time_sync_ack.payload` (optional field), making correlation unambiguous.

## 3. `resume`'s `play_at` units (§9.3)
The `resume` row lists `+ play_at` for synchronized resume but doesn't restate
that it's broker-master-clock ms. Implemented as master-clock ms folded via §8.2
(`local = play_at - offset`), consistent with `play_at` in §9.2. If `resume`
intends a different time base this should be stated.

## 4. `set_audio_master` default semantics (§9.3)
§9.3 says "默认组内全部出声" (default: all in group output). The command field
is `device_ids:[…]`. Implemented: empty/absent `device_ids` → this device is a
master (un-muted); non-empty → master iff our `device_id` is in the list, else
muted. Confirm an explicit empty list `[]` means "everyone" (current behavior)
versus "no one".

## 5. `welcome.assigned` meaning for players (§4.2)
`welcome.payload.assigned` is shown but its player-side meaning isn't spelled
out (it reads more controller-oriented alongside `snapshot`). Player currently
only flags `assigned:false` as a soft error and otherwise proceeds. If
`assigned:false` should pause playback / re-hello, please specify.
