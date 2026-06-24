# Notes to upstream — broker implementation observations

These are non-blocking ambiguities found while implementing the broker against
`protocol_spec.md` v1. I implemented the safest reasonable interpretation and
kept using the existing protocol (no spec changes made). Listed here so the
contract can be tightened in a future revision if desired.

## 1. `ready` frame lacks a session/correlation id (§9.1)

The `ready` payload carries `device_id` + `playlist_id` + `ready`, but no
reference to the originating `prepare` (e.g. its `msg_id`) nor a `group_id`.

- **What I did:** the broker keys an in-flight sync session by the `prepare`'s
  `msg_id` and indexes it by `group_id`. A `ready` is matched to a session by
  looking up the device's current `group_id` in the registry. This assumes at
  most one active `prepare` per group at a time (true for the current control
  model) and that a device's group doesn't change between `prepare` and
  `ready`.
- **Suggestion:** add `group_id` (and optionally `prepare_id`) to the `ready`
  payload so matching is explicit and concurrent prepares per group become
  possible.

## 2. `play_at` does not echo a `prepare`/session id (§9.2)

Same root cause as (1). Players correlate `play_at` to the pending prepare by
`playlist_id` + `group_id`. Fine today; an explicit id would be more robust if
overlapping playlists per group ever happen.

## 3. Exact field set of the `wall.devices[]` "status subset" is unspecified (§5.2)

§5.2 says devices carry "a subset of the §5.1 status fields + last_seen" but
doesn't enumerate which. The broker currently forwards the full last `status`
payload plus `device_name`, `group_id`, `last_ip`, `online`, `last_seen`.
Controllers should treat unknown/missing fields defensively.

## 4. `welcome` payload — added `group_id` and `v` for players

§4.2 shows `welcome` with `assigned`, `server_time`, and (for controllers)
`snapshot`. The broker additionally returns `v` (protocol version, per §12
"broker returns v in welcome") and, for players, the authoritative `group_id`
the registry assigned (since §4.1 says "broker is authoritative and may
override"). These are additive optional fields and don't break the contract.

## 5. `time_sync` cadence is player-driven

§8.1 says time_sync runs "on connect + every 30s". The broker responds to every
`time_sync` it receives (stamping t2 at receive, t3 at send) but does not itself
poll players — the player owns the 30s cadence. `time_sync_interval_ms` exists
in config as documentation/forward-compat but the broker is purely reactive here.

---

# v1.2 additions (§13–§15) — ambiguities resolved

These were resolved with the safest backward-compatible default while
implementing the v1.2 broker side. None change the contract.

## 6. `announce` payload field names for topology/auth_mode (§7/§13/§14.5)

§13/§14 say the coordinator declares `auth_mode` and `topology` "in the UDP
`announce.payload`", and §7's announce example carries `broker_hint`, but the
exact key names/extra fields for a *broker-originated* announce aren't spelled
out (the §7 example is a *player* announce with `device_id`/`device_name`).

- **What I did:** the broker's `announce.payload` carries
  `{broker_hint, ws_port, auth_mode, topology}` using those literal key names
  (matching `welcome.payload.auth_mode`/`topology` from §13/§14). It omits the
  player-only `device_id`/`device_name`. Consumers should treat unknown fields
  defensively (already required by §5.1).
- **Suggestion:** add an explicit broker-announce example to §14.5 fixing these
  key names.

## 7. `welcome` gains `auth_mode`, `topology` (and `minor`) (§13/§14)

§4.2/§13/§14 say the coordinator declares `auth_mode` and `topology` in
`welcome.payload`. The broker adds both, plus `minor: 2` (the implemented v1.2
minor; `v` stays `1` per the v1.2 preamble) alongside the existing `v`. Also,
for players, `controllers_online` is included in the initial welcome (it was
already specced in v1.1 §4.2 but wasn't being sent on the first frame). All
additive/optional.

## 8. PSK requirement relaxed for `open`/`optional` (§13)

The v1 broker hard-exited at startup when no PSK was configured. §13 makes a PSK
unnecessary in `open`/`optional`. The broker now only requires a PSK in
`required` mode; otherwise it runs keyless and (per the §13 table) either never
verifies (`open`) or verifies only non-empty sigs (`optional`). This is the
zero-config default and is backward-compatible (an explicit `required` + PSK
reproduces the old strict behavior exactly).

## 9. Pairing URI fixed query params (§15.1)

§15.1 lists `host,port,group,mode,psk?,wss,name?`. Order isn't specified; I emit
them in that listed order, URL-encode every value, omit `psk` entirely in `open`
(and whenever no PSK is set), and encode `wss` as `0`/`1`. Unknown query params
are preserved on parse but should be ignored by consumers (§15.1).

