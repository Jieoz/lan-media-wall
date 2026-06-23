# Notes to upstream — Android player

Observations from implementing the Android被控端 against `protocol_spec.md` v1.1
and the existing `broker/` + `windows_player/`. None block the Android player
(it is spec-compliant and degrades gracefully), but they affect cross-end v1.1
behavior and are worth a look on the broker side.

## 1. broker does not inject `prepare_id` into the forwarded `prepare` (§9.1)

`protocol_spec.md` §9.1 [v1.1] says the broker assigns `prepare_id` (= the
prepare's `msg_id`) and includes it in the prepare frame fanned out to the
group. In `broker/broker.py::_on_prepare`, the forward is:

```python
fwd = self.make_env("prepare", p, f"group:{group_id}")
```

i.e. it forwards the controller's original payload `p` unchanged, which has no
`prepare_id`. So players receive `prepare` **without** `prepare_id`.

- Android impact: none — we echo `prepare_id` back when present and the broker
  matches by `group_id`+`playlist_id` otherwise (the documented fallback). But
  the concurrent-session-by-prepare_id feature is effectively inactive until the
  broker injects it. Suggest: `p = {**p, "prepare_id": env["msg_id"]}` before
  fanout, and use it in `sync.start(...)` / `_on_ready` matching.

## 2. `time_sync_ack` omits `req_msg_id` (§8.1 v1.1)

§8.1 [v1.1] specifies the broker echo `req_msg_id` (the original `time_sync`
`msg_id`) in `time_sync_ack.payload` to disambiguate same-millisecond `t1`
collisions. `broker/clock.py::build_time_sync_ack_payload` returns only
`{t1,t2,t3}`.

- Android impact: none in practice — we correlate by `t1` (the documented
  backward-compatible fallback), same as `windows_player`. Flagging only so the
  v1.1 `req_msg_id` path can be completed broker-side if same-ms collisions are
  ever a concern at 30 players × 30s cadence.

## 3. `ready` matching uses group only, not `prepare_id` (§9.1)

`broker/broker.py::_on_ready` resolves the session via the player's
`group_id` (`self.sync.on_ready(group_id, device_id)`), not the echoed
`prepare_id`. Consistent with #1 (no prepare_id is in flight). Same suggestion:
once prepare_id is injected, key the ready-collection session on it to support
concurrent same-group sessions as §9.1 intends.

---

These are consistency/feature-completeness items for the v1.1 additions, not
correctness bugs for the current single-session-per-group flow. The Android
player interoperates today via the documented fallbacks.
