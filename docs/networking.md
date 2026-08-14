# Chalk Gaon — Networking Architecture & Protocol (Prompt 17)

Everything done for the Nakama multiplayer pass: lobby + room codes, host
migration, reconnect, minimal-bandwidth binary protocol, and the
server-authoritative model. All code is **static** (no Godot engine on this
machine); anything that needs a live Nakama server, a real device, or a
Godot editor run is called out in [§13 What needs a live server / device](#13-what-needs-a-live-server--device-to-verify).

---

## 1. Overview

The prototype's game loop (draw chalk lines → hunt ghost lines → accuse →
score) is fully local today. This PR adds the **network transport + protocol
layer** the loop will run on, without converting the loop itself (that is the
next milestone — see [§14 Next milestone](#14-next-milestone)).

Deliverables in this PR:

| File | Role |
|---|---|
| `scripts/autoload/NetworkManager.gd` | reworked: transport abstraction hub, wires everything, UI API |
| `scripts/autoload/EventBus.gd` | +18 `EV_NET_*` constants (lobby/host/reconnect/match events) |
| `scripts/networking/NetSerializer.gd` | compact binary wire protocol (PackedByteArray, not JSON) |
| `scripts/networking/LobbyManager.gd` | room codes, player roster, ready state |
| `scripts/networking/HostMigration.gd` | heartbeats, host-lost detection, re-election, state transfer |
| `scripts/networking/ReconnectManager.gd` | session resume (SaveManager), backoff, rejoin + resync |
| `scripts/networking/MatchSession.gd` | transports (Nakama REST+WS / simulated / offline), tick loop, batching, bandwidth accounting |
| `scripts/networking/AuthorityGuard.gd` | client-side authority enforcement per role |
| `docs/networking.md` | this document |

Layering: **game systems → NetworkManager (the only singleton they touch) →
session layer → transport (Nakama / simulated / offline)**. The game layer
never imports `scripts/networking/*` directly; it calls
`NetworkManager.create_lobby(...)`, `NetworkManager.send_line_drawn(...)`
etc. and listens to `EV_NET_LOBBY_*` / `EV_NET_HOST_*` / `EV_NET_RECONNECT_*`
/ `EV_NET_MATCH_*` events.

---

## 2. Transport selection

```
NetworkManager.start_online(url, token)
  └─ MatchSession.connect_to_server(url)
       ├─ SIMULATE_SERVER = true  → in-process fake server (editor testing)
       ├─ url configured         → Nakama REST (authenticate → match create/join)
       │                            then WebSocket for match data
       └─ url empty / failure     → EV_NET_OFFLINE → local offline loop
NetworkManager.start_offline()    → OFFLINE mode, this device = HOST (WiFi Direct
                                    when the native plugin lands — §11)
```

Config constants live in `MatchSession` (top of file): `NAKAMA_SERVER_URL`
(empty = offline), `NAKAMA_SERVER_PORT`, `NAKAMA_USE_TLS`, `NAKAMA_SERVER_KEY`,
`SIMULATE_SERVER`. Point `NAKAMA_SERVER_URL` at the future deployment to
activate the online path — nothing else changes.

**Degradation contract**: if no server is configured or any connection step
fails, `MatchSession` emits `EV_NET_OFFLINE {reason}`, `NetworkManager` flips
to `Mode.OFFLINE` / `Authority.HOST` and the existing local loop continues
unaffected. No gameplay code has to handle the network at all to stay
playable.

---

## 3. Authority model

| Mode | Authority | State owner | Guard role | Input flow |
|---|---|---|---|---|
| Online (Nakama) | Server | Nakama match handler | CLIENT | Client → Server (validate) → broadcast |
| Offline (WiFi Direct) | Elected host | Host device | HOST | Peer → Host (trust) → broadcast |
| Offline fallback (no server) | Local device | Local loop | HOST | local only |

- **Online**: the Nakama server (server-side match handler, reference notes in
  §12) validates every action and is the single source of truth. Clients are
  renderers + predictors; the client-side `AuthorityGuard` is defense-in-depth
  — it rejects out-of-role actions locally *before* they reach the wire.
- **Offline**: one device is host (first to create the room). No cheat
  protection — trusted local play.
- **Host migration** applies to the offline/hosted model (§8). In online mode
  the server is the authority and never "drops" — a host concept exists only
  for ordering/relay.

### 3.1 AuthorityGuard action table (`scripts/networking/AuthorityGuard.gd`)

| Action | Allowed roles | Ownership check |
|---|---|---|
| `line.draw` | CLIENT, HOST, SERVER | must be self |
| `ghost.place` | CLIENT, HOST, SERVER | — |
| `ghost.discover` | CLIENT, HOST, SERVER | — |
| `accusation.start` | CLIENT, HOST, SERVER | must be self |
| `accusation.resolve` | HOST, SERVER | — |
| `score.commit` | HOST, SERVER | — |
| `state.change` | HOST, SERVER | — |
| `lobby.close`, `match.start` | HOST | — |
| `ready.toggle` | CLIENT, HOST, SERVER | must be self |

Rejected actions emit `EV_NET_ACTION_REJECTED {action, player_id, reason,
role}` and never reach the transport.

---

## 4. Message protocol (binary)

Every message is an **envelope** produced by `NetSerializer`:

```
[0]    u8   message type (MsgType)
[1]    u8   flags (bit0 needs_ack, bit1 is_delta, bit2 reliable)
[2..3] u16  sequence number (per-sender, wraps at 65535)
[4..]       typed payload (fixed-width little-endian primitives)
```

No JSON travels the wire. Strings are `u8 length + UTF-8` (capped 255 B);
`Vector2` is 2×`i16` quantized to 0.5 px (matches `ChalkLine` compression);
blobs are `u16 length + bytes`. All decode paths are bounded by
`MAX_PAYLOAD / MAX_POINTS / MAX_PLAYERS / MAX_LINES`.

### 4.1 Message types

| # | Name | Direction | Payload layout | Payload bytes (typical) |
|---|---|---|---|---|
| 1 | HELLO | C→S | name: str, role: u8 | ~12 |
| 2 | HEARTBEAT | all | seq: u16, match_state: u8, round: u8 | 4 |
| 3 | SNAPSHOT | S/H→C | magic u16 "CG", ver u8, match_state u8, round u8, flags u8, phase_msec u32, last_seq u32, players[ ], lines[ ] | < 2048 |
| 4 | STATE_DELTA | S/H→C | match_state u8 (0xFF=unchanged), round u8, flags u8, last_seq u32, players[ ] (masked fields), lines_added[ ], lines_removed[ ] | ~10–70 |
| 5 | STATE_CHANGE | S/H→C | match_state u8, round u8, flags u8 | 3 |
| 6 | READY | C→S/H | player_id u8, ready u8 | 2 |
| 7 | PLAYER_JOINED | S/H→C | id u8, is_host u8, name str | ~8 |
| 8 | PLAYER_LEFT | S/H→C | player_id u8 | 1 |
| 9 | HOST_TRANSFER | H→C | new_host u8, last_seq u32, snapshot blob | ~snapshot + 7 |
| 10 | HOST_ELECTED | H→C | (broadcast result of re-election) | 0 |
| 11 | RECONNECT | C→S/H | room_code str, token str | ~24 |
| 12 | RESYNC | C→S/H | last_seq u32 (request; reply is a SNAPSHOT) | 4 |
| 16 | LINE_DRAWN | C→S/H | ChalkLine network dict, see §4.2 | 53–93 |
| 17 | GHOST_LINE_PLACED | S/H→C | same as 16 + ghost fields (go u8, gp u32) | 58–98 |
| 18 | GHOST_LINE_DISCOVERED | C→S/H | line_ids (u8 count + u16 each) | ~5 |
| 19 | ACCUSATION | C→S/H | argument_id u16, accuser u8, target u8 | 4 |
| 20 | ACCUSATION_RESOLUTION | S/H→C | argument_id u16, flags u8 (bit0 is_true, bit1 penalty) | 3 |
| 21 | SCORE | S/H→C | player_id u8, round u8, score i32 | 6 |
| 31 | ACK | all | — | 0 |
| 32 | ERROR | S→C | message str | — |

### 4.2 LINE_DRAWN layout (ChalkLine network dict ↔ bytes)

```
id: i16 | ct: u8 | pid: u8 | t: u32 (msec) | dd: i16 (decay s; -1 = ghost sentinel)
| cn: u8 count + u16 each (connected line ids)
| pc: u16 (point count) | pd: blob (delta-encoded int16 positions, 4 B/point)
| wd: blob (uint8 widths, 1 B/point)
| flags: u8 (bit0 ghost, bit1 discovered)
| if ghost: go: u8 (owner), gp: u32 (placed msec)
```

Reuses `ChalkLine.to_network_dict()/from_network_dict()` unchanged — the
existing RDP simplification + delta encoding + 16-bit quantization is the
payload; `NetSerializer` only adds the typed envelope.

---

## 5. Byte budgets & bandwidth math (6-player game)

### Per-event budgets (payload + 4 B envelope)

| Event | Payload | Wire total |
|---|---|---|
| HEARTBEAT | 4 | **8 B** |
| STATE_CHANGE | 3 | **7 B** |
| STATE_DELTA (no changes) | 7 | **11 B** |
| READY | 2 | **6 B** |
| ACCUSATION | 4 | **8 B** |
| ACCUSATION_RESOLUTION | 3 | **7 B** |
| SCORE | 6 | **10 B** |
| RECONNECT | ~24 | **~28 B** |
| LINE_DRAWN (5 simplified pts, no connections) | 53 | **57 B** |
| LINE_DRAWN (10 pts) | 88 | **92 B** |
| GHOST_LINE_PLACED (5 pts) | 58 | **62 B** |
| SNAPSHOT (6 players, 10 lines) | ~650 | **~654 B** (< 2 KB target) |

All typical events are **well under 100 B**. A dense 10-point line is 92 B;
the 100 B budget is enforced by `MAX_EVENT_BYTES` in `MatchSession`
(overruns emit `EV_NET_BANDWIDTH_WARNING`).

### Steady-state bandwidth (10 Hz tick, 1 full snapshot / 5 s)

| Stream | Rate |
|---|---|
| Heartbeats (6 × 8 B / 2 s) | 24 B/s |
| State deltas (6 × ~11 B × 10 Hz → delta-only, realistic ~30 B avg × 5 Hz) | ~150 B/s |
| Full snapshot 654 B / 5 s | ~131 B/s |
| Lines (6 players × 6 draws/min × 57 B) | ~34 B/s |
| Accusations / scoring (rare) | ~1 B/s |
| **Per-client downlink** | **≈ 340 B/s ≈ 2.7 kb/s** |
| **Server aggregate (6 clients)** | **≈ 2 KB/s ≈ 16 kb/s** |

Conclusion: the protocol is ~100× under a typical mobile data budget; even a
100-line match in progress stays below 4 KB/s per client. The dominant cost
is the per-event envelope + line geometry, both already minimized.

---

## 6. Rate limiting & batching

- **Tick rate**: `UPDATE_HZ = 10` (100 ms). Outbound messages are queued and
  flushed once per tick (batch), so 10 system sends in one frame cost one
  flush.
- **Delta-only**: the authority diffs current authoritative state against the
  last-sent state; unchanged fields are `0xFF` markers; only added/removed
  lines and changed player fields travel. A full snapshot is sent every
  `FULL_SNAPSHOT_EVERY_TICKS = 50` (1 Hz... 1 per 5 s) as a resync anchor.
- **Budgets**: `MAX_OUTBOUND_BYTES_PER_SEC = 4096` (rolling 1 s window) and
  `MAX_EVENT_BYTES = 256` (per message). Overruns emit
  `EV_NET_BANDWIDTH_WARNING`; payloads over `MAX_PAYLOAD = 4096` are dropped
  with a warning.
- **Stats**: `MatchSession.get_stats()` exposes bytes sent/received and queue
  depth for the ProfilerOverlay/debug HUD.

---

## 7. Lobby & room codes

`LobbyManager` API (UI should call `NetworkManager.*` and listen for
`EV_NET_LOBBY_*`):

| Call | Event on completion | Notes |
|---|---|---|
| `create_lobby(name)` → code | `EV_NET_LOBBY_CREATED {room_code, ok}` | 6-char code; collision-tolerant |
| `join_lobby(code)` → bool | `EV_NET_LOBBY_JOINED {room_code, ok, reason}` | reason: bad_format / not_found / full / timeout |
| `leave_lobby()` | `EV_NET_LOBBY_LEFT`, `EV_NET_LOBBY_CLOSED` (host) | |
| `set_ready(bool)` | `EV_NET_LOBBY_PLAYER_READY {player_id, ready}` | |
| `start_match()` (host) | `EV_NET_MATCH_STATE_SYNC` on peers | host-only, guard-checked |
| `get_players()` / `get_room_code()` | — | roster snapshot |

**Room codes**: 6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (31 chars, no
confusables) → ~887 M codes. On the Nakama path the code is passed as the
**custom match id** at `POST /v2/match/create` (`{"params":{"room_code":...}}`),
which makes create-with-code atomic server-side; a collision (code already in
use) fails the create and `LobbyManager` retries with a fresh code
(`MAX_ROOM_CODE_ATTEMPTS = 5`). Nakama custom ids allow 6–128 alphanumeric
chars, so a 6-char code is valid. In the simulated transport the same
collision logic runs against the in-process room registry.

**Async note**: on the real transport, create/join are HTTP requests — the
result arrives asynchronously (`CreateResult.PENDING` / `JoinResult.PENDING`);
the UI must listen to the events, never block on the return value. Simulated
and offline modes are synchronous.

---

## 8. Host migration (offline / hosted model)

Sequence (constants in `HostMigration`):

```
t = 0 s        every peer sends HEARTBEAT every 2 s (HEARTBEAT_INTERVAL)
t = 6 s        host's heartbeats missing for 3 × 2 s (MISSED_HEARTBEAT_THRESHOLD)
               → EV_NET_HOST_LOST {host_id} on every remaining peer
               → deterministic re-election: LOWEST remaining session id wins
                 (all peers compute the same answer — no voting round)
new host       → EV_NET_HOST_ELECTED {host_id}
               → rebuilds authoritative state = local mirror + replay of the
                 confirmed-event log (entries with seq > last_seq)
               → broadcasts HOST_TRANSFER {new_host, last_seq, snapshot}
every peer     → applies snapshot, updates host pointer
               → EV_NET_HOST_TRANSFERRED {new_host_id, last_seq}
t = +4 s       no transfer received → EV_NET_HOST_LOST {unrecoverable: true}
               → match cannot continue → RETURN_TO_LOBBY
```

- **State transfer basis**: each peer keeps (a) the latest authoritative
  snapshot mirror and (b) a ring buffer of confirmed events
  (`HostMigration.append_event`, capped at 256). A new host replays events
  newer than its last confirmed seq, so a mid-round migration continues the
  current round/phase rather than restarting.
- **Determinism**: re-election uses the stable per-device session id
  (`hash(device_id)`); lowest wins. Ties are impossible because ids are
  unique.
- In **online mode** the Nakama server is the authority and never migrates —
  this machinery only runs when `NetworkManager.hosted_mode(true)` (offline
  start or offline fallback).

---

## 9. Reconnect flow

Session credentials persist under `SaveManager` key `"net_session"`:
`{device_id, auth_token, refresh_token, user_id, last_room_code,
reconnect_token}` (reconnect_token = user/session id; the authority compares
it when a peer rejoins).

```
drop detected (socket closed / HTTP failure)
  → ReconnectManager.on_connection_lost()
  → backoff: 1 s, 2 s, 4 s, 8 s, 16 s, 30 s max, ±20 % jitter
    (BASE_BACKOFF × BACKOFF_MULTIPLIER, MAX_RECONNECT_ATTEMPTS = 5)
  → each attempt:
      authenticate (refresh token preferred, else device auth)  [Nakama path]
      rejoin last_room_code via /v2/match/join
      send RECONNECT {room_code, reconnect_token}
      authority replies RESYNC (full authoritative snapshot)
  → success: EV_NET_RECONNECTED → state resync applied (players/round/phase)
  → exhausted: EV_NET_RECONNECT_FAILED → EV_NET_OFFLINE → local loop
```

`ReconnectManager.try_now()` forces an immediate attempt (app-foreground /
explicit retry). `NetworkManager.persist_session_for_resume()` writes
credentials after a successful online connect.

---

## 10. Offline fallback (no server)

`NAKAMA_SERVER_URL` empty, or any REST/WS step failing, or reconnect
exhausted → `EV_NET_OFFLINE {reason}` → `NetworkManager` sets
`Mode.OFFLINE`, `Authority.HOST`, `hosted_mode(true)`, guard role HOST. The
existing local game loop (DrawSystem, GhostDrawSystem, ArgumentSystem,
ScoringManager, MatchStateMachine) runs exactly as before — `has_authority()`
returns true, `send_rpc` is a local echo. No gameplay change is required.

---

## 11. WiFi Direct limitation (documented, not implemented)

WiFi Direct local play is planned but **not implemented in this PR**: it needs
an **Android-only native plugin** (Godot Android plugin / JNI bridge over
`WifiP2pManager`) exposing peer discovery, group formation, and a socket to
GDScript. The architecture already absorbs it: `NetworkManager.start_offline()`
is the seam, `Mode.OFFLINE` + `Authority.HOST` is the model it plugs into, and
the binary protocol is transport-agnostic (it works over any byte stream).
Export preset permissions for it (`ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`,
`CHANGE_NETWORK_STATE`, `ACCESS_FINE_LOCATION`, `NEARBY_WIFI_DEVICES`) are
already present. Desktop/editor offline play today = plain local loop.

---

## 12. Server-side reference (Nakama match handler)

The Godot repo cannot ship server code; these are the authoritative rules the
future Nakama match handler (Lua/Go/TS) must implement. This is a reference,
not a patch:

```
match_init(context, params):
    room_code = params["room_code"]            # custom match id = room code
    state = { match_state: LOBBY, round: 0, players: {}, lines: [], seq: 0 }
    return state

match_join_attempt / match_join:
    if len(players) >= 6: reject (FULL)
    players[user_id] = {name, ready: false, score: 0, is_host: first}

match_loop / match_data (op_code 0 = our envelope):
    decode NetSerializer envelope
    HEARTBEAT      → update presence timestamp
    READY          → set ready; broadcast
    LINE_DRAWN     → VALIDATE: sender == pid, chalk_type ∈ {0,1,2,3},
                     point count sane, geometry bounds-checked
                     → assign server line id, seq++, broadcast
    GHOST_LINE_PLACED → VALIDATE: only ghost-role players, count limits
                     → broadcast
    ACCUSATION     → VALIDATE: accuser != target, once per round per target
                     → resolve server-side (target's ghost flag is
                       authoritative), compute penalty, broadcast
                     ACCUSATION_RESOLUTION + SCORE
    SCORE          → never accepted from clients (server-computed only)
    STATE_CHANGE   → only host/server path; broadcast to all
    RECONNECT      → check reconnect_token == user_id, reply RESYNC
    RESYNC         → reply SNAPSHOT

authoritative rules to enforce:
  1. Ghost-line placement is decided by the server/host — clients only
     request; placement is broadcast, never client-announced.
  2. Accusation resolution is validated server-side — the server holds the
     true ghost/spectator flags; clients never send "is_true".
  3. Scores are computed from server-confirmed events only (round scoring
     uses the server's line/ghost/accusation records), then broadcast.
  4. State transitions go through the server's state machine; clients apply
     the broadcast STATE_CHANGE/SNAPSHOT and do NOT mutate local authority
     state.
```

---

## 13. What needs a live server / device to verify

- **Nakama REST flow**: device authenticate, match create with custom id
  (room code), collision handling, match join, leave — requires a deployed
  Nakama server and `NAKAMA_SERVER_URL` set. Code paths:
  `MatchSession._rest_authenticate / create_match / join_match /
  _on_http_completed`.
- **WebSocket match data**: handshake, `match_data_send` framing, presence
  events, socket-drop → reconnect trigger — requires the server (`_open_websocket
  / _poll_ws / _handle_ws_message`).
- **Session resume across app restarts**: real refresh-token flow.
- **Bandwidth measurement on device**: ProfilerOverlay stats + the §5 math
  should be re-measured on-device with a real match.
- **End-to-end loop** (next milestone): driving MatchStateMachine and the
  systems from received events.

What CAN be verified without a server: everything under the SIMULATED
transport (`SIMULATE_SERVER = true` — two editor instances can share the
in-process room registry: create/join by code, roster sync, ready, match
start, host-change simulation) and the offline fallback (default config:
game boots, `EV_NET_OFFLINE`, local loop intact).

---

## 14. Next milestone

Convert the live game loop to the binary protocol:

1. Replace `NetworkManager.send_rpc(...)` call sites (DrawSystem,
   GhostDrawSystem, ArgumentSystem, ScoringManager) with the typed senders
   (`send_line_drawn`, `send_ghost_line_placed`, `send_accusation`, ...).
2. Feed authoritative state from the host/server into
   `NetworkManager.update_authoritative_state(...)` each tick.
3. Apply received gameplay events (`EV_NET_MATCH_EVENT` payloads) to the
   local systems (decode via `NetSerializer.decode_line` etc.).
4. Drive `MatchStateMachine` from `EV_NET_MATCH_STATE_SYNC` instead of local
   transitions on remote devices.
5. Build the lobby UI scene against the `NetworkManager` API + `EV_NET_*`
   events (documented above).
