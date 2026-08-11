# NetSerializer.gd — Compact binary wire protocol (PackedByteArray), NOT JSON.
#
# Every network message is an envelope:
#   [0]    u8   message type (MsgType)
#   [1]    u8   flags (FLAG_*)
#   [2..3] u16  sequence number (per-sender, wraps at 65535)
#   [4..]       typed payload (see docs/networking.md for byte layouts)
#
# All primitives are fixed-width little-endian. No dictionaries travel the
# wire — systems convert to/from packed fields through this class.
#
# Bandwidth targets (see docs/networking.md §5):
#   - typical event payload   < 100 bytes
#   - full state snapshot     < 2048 bytes
#
# Layouts match ChalkLine.to_network_dict()/from_network_dict() so existing
# compression (RDP simplification, delta encoding, 16-bit quantized points)
# is reused unchanged — this class only adds the binary envelope.

class_name NetSerializer
extends RefCounted

# ── Message types ─────────────────────────────────────────────────────────
enum MsgType {
	NONE = 0,
	HELLO = 1,               # handshake: name + role
	HEARTBEAT = 2,           # liveness (HostMigration)
	SNAPSHOT = 3,            # full authoritative state
	STATE_DELTA = 4,         # only changed fields
	STATE_CHANGE = 5,        # match state transition notification
	READY = 6,               # lobby ready toggle
	PLAYER_JOINED = 7,       # presence
	PLAYER_LEFT = 8,         # presence
	HOST_TRANSFER = 9,       # authority handoff + snapshot
	HOST_ELECTED = 10,       # re-election result broadcast
	RECONNECT = 11,          # rejoin request (room code + token)
	RESYNC = 12,             # full snapshot in response to RECONNECT
	LINE_DRAWN = 16,         # chalk line placed (ChalkLine network dict)
	GHOST_LINE_PLACED = 17,  # ghost line placed (authority only)
	GHOST_LINE_DISCOVERED = 18,
	ACCUSATION = 19,
	ACCUSATION_RESOLUTION = 20,
	SCORE = 21,
	ACK = 31,
	ERROR = 32,
	COUNT = 33,              # sentinel: number of message types
}

# ── Envelope flags ────────────────────────────────────────────────────────
const FLAG_NEEDS_ACK := 1
const FLAG_IS_DELTA := 2
const FLAG_RELIABLE := 4

const ENVELOPE_SIZE := 4

# Sanity caps — protect decode loops from malformed buffers.
const MAX_PAYLOAD := 4096
const MAX_STRING_LEN := 128
const MAX_POINTS := 2048
const MAX_PLAYERS := 32
const MAX_LINES := 512

# ── ByteWriter / ByteReader ───────────────────────────────────────────────

class ByteWriter:
	extends RefCounted
	var data := PackedByteArray()

	func u8(v: int) -> void:
		data.append(v & 0xFF)

	func u16(v: int) -> void:
		data.append(v & 0xFF)
		data.append((v >> 8) & 0xFF)

	func u32(v: int) -> void:
		data.append(v & 0xFF)
		data.append((v >> 8) & 0xFF)
		data.append((v >> 16) & 0xFF)
		data.append((v >> 24) & 0xFF)

	func i16(v: int) -> void:
		u16(v & 0xFFFF)

	func i32(v: int) -> void:
		u32(v & 0xFFFFFFFF)

	func f32(v: float) -> void:
		data.append_array(PackedFloat32Array([v]).to_byte_array())

	## UTF-8 string, u8 length prefix (capped at 255 bytes).
	func string(s: String) -> void:
		var bytes := s.to_utf8_buffer()
		if bytes.size() > 255:
			bytes = bytes.slice(0, 255)
		u8(bytes.size())
		data.append_array(bytes)

	## Quantized Vector2 (×2 → 0.5px precision, matches ChalkLine).
	func v2(v: Vector2) -> void:
		i16(int(round(v.x * 2.0)))
		i16(int(round(v.y * 2.0)))

	## Raw bytes with u16 length prefix.
	func raw_bytes(b: PackedByteArray) -> void:
		u16(b.size())
		data.append_array(b)


class ByteReader:
	extends RefCounted
	var data: PackedByteArray
	var pos := 0

	func _init(buf: PackedByteArray) -> void:
		data = buf

	func remaining() -> int:
		return data.size() - pos

	func u8() -> int:
		if remaining() < 1:
			return 0
		var v := data[pos]
		pos += 1
		return v

	func u16() -> int:
		if remaining() < 2:
			return 0
		var v := data[pos] | (data[pos + 1] << 8)
		pos += 2
		return v

	func u32() -> int:
		if remaining() < 4:
			return 0
		var v := data[pos] | (data[pos + 1] << 8) | (data[pos + 2] << 16) | (data[pos + 3] << 24)
		pos += 4
		return v

	func i16() -> int:
		var v := u16()
		if v >= 0x8000:
			v -= 0x10000
		return v

	func i32() -> int:
		var v := u32()
		if v >= 0x80000000:
			v -= 0x100000000
		return v

	func f32() -> float:
		if remaining() < 4:
			return 0.0
		var bytes := data.slice(pos, pos + 4)
		pos += 4
		var arr := bytes.to_float32_array()
		return arr[0] if arr.size() > 0 else 0.0

	func string() -> String:
		var len := u8()
		if len == 0 or remaining() < len:
			return ""
		var bytes := data.slice(pos, pos + len)
		pos += len
		return bytes.get_string_from_utf8()

	func v2() -> Vector2:
		return Vector2(float(i16()) / 2.0, float(i16()) / 2.0)

	func raw_bytes() -> PackedByteArray:
		var len := u16()
		if remaining() < len:
			return PackedByteArray()
		var bytes := data.slice(pos, pos + len)
		pos += len
		return bytes


# ── Envelope ──────────────────────────────────────────────────────────────

static func encode(type: int, seq: int, payload: PackedByteArray, flags := 0) -> PackedByteArray:
	var out := PackedByteArray()
	out.append(type & 0xFF)
	out.append(flags & 0xFF)
	out.append(seq & 0xFF)
	out.append((seq >> 8) & 0xFF)
	out.append_array(payload)
	return out

static func decode(buf: PackedByteArray) -> Dictionary:
	if buf.size() < ENVELOPE_SIZE:
		return {}
	return {
		"type": buf[0],
		"flags": buf[1],
		"seq": buf[2] | (buf[3] << 8),
		"payload": buf.slice(ENVELOPE_SIZE),
	}


# ── Simple messages ───────────────────────────────────────────────────────

static func encode_hello(player_name: String, role: int) -> PackedByteArray:
	var w := ByteWriter.new()
	w.string(player_name)
	w.u8(role)
	return w.data

static func decode_hello(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"name": r.string(), "role": r.u8()}

static func encode_heartbeat(seq: int, match_state: int, round_number: int) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u16(seq)
	w.u8(match_state)
	w.u8(round_number)
	return w.data

static func decode_heartbeat(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"seq": r.u16(), "match_state": r.u8(), "round": r.u8()}

static func encode_ready(player_id: int, ready: bool) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u8(player_id)
	w.u8(1 if ready else 0)
	return w.data

static func decode_ready(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"player_id": r.u8(), "ready": r.u8() != 0}

static func encode_state_change(match_state: int, round_number: int, flags: int) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u8(match_state)
	w.u8(round_number)
	w.u8(flags)
	return w.data

static func decode_state_change(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"match_state": r.u8(), "round": r.u8(), "flags": r.u8()}

static func encode_score(player_id: int, round_number: int, score: int) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u8(player_id)
	w.u8(round_number)
	w.i32(score)
	return w.data

static func decode_score(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"player_id": r.u8(), "round": r.u8(), "score": r.i32()}

static func encode_accusation(argument_id: int, accuser_id: int, target_id: int) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u16(argument_id)
	w.u8(accuser_id)
	w.u8(target_id)
	return w.data

static func decode_accusation(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"argument_id": r.u16(), "accuser_id": r.u8(), "target_id": r.u8()}

static func encode_accusation_resolution(argument_id: int, is_true: bool, penalty_applied: bool) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u16(argument_id)
	var flags := 0
	if is_true:
		flags |= 1
	if penalty_applied:
		flags |= 2
	w.u8(flags)
	return w.data

static func decode_accusation_resolution(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	var argument_id := r.u16()
	var flags := r.u8()
	return {
		"argument_id": argument_id,
		"is_true": (flags & 1) != 0,
		"penalty_applied": (flags & 2) != 0,
	}

static func encode_reconnect(room_code: String, token: String) -> PackedByteArray:
	var w := ByteWriter.new()
	w.string(room_code)
	w.string(token)
	return w.data

static func decode_reconnect(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"room_code": r.string(), "token": r.string()}

static func encode_resync(last_seq: int) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u32(last_seq)
	return w.data

static func decode_resync(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"last_seq": r.u32()}

static func encode_host_transfer(new_host_id: int, last_seq: int, snapshot: PackedByteArray) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u8(new_host_id)
	w.u32(last_seq)
	w.raw_bytes(snapshot)
	return w.data

static func decode_host_transfer(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"new_host_id": r.u8(), "last_seq": r.u32(), "snapshot": r.raw_bytes()}

static func encode_player_joined(player: Dictionary) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u8(player.get("id", 0))
	w.u8(1 if player.get("is_host", false) else 0)
	w.string(str(player.get("name", "")))
	return w.data

static func decode_player_joined(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	var pid := r.u8()
	return {"player": {"id": pid, "is_host": r.u8() != 0, "name": r.string()}}

static func encode_player_left(player_id: int) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u8(player_id)
	return w.data

static func decode_player_left(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	return {"player_id": r.u8()}


# ── Line payloads (ChalkLine network dict ↔ bytes) ────────────────────────
#
# Layout (matches to_network_dict() keys):
#   id i16 | ct u8 | pid u8 | t u32 | dd i16 | cn: u8 count + u16 each |
#   pc u16 | pd raw | wd raw | flags u8 (bit0 ghost, bit1 discovered)
#   if ghost: go u8 | gp u32

static func encode_line(line: Dictionary) -> PackedByteArray:
	var w := ByteWriter.new()
	w.i16(line.get("id", -1))
	w.u8(line.get("ct", 0))
	w.u8(line.get("pid", 0))
	w.u32(int(line.get("t", 0)))
	w.i16(int(line.get("dd", -1)))  # decay seconds; -1 = ghost sentinel
	var cn: Array = line.get("cn", [])
	w.u8(clampi(cn.size(), 0, 255))
	for cid in cn:
		w.u16(int(cid))
	var pc: int = line.get("pc", 0)
	w.u16(clampi(pc, 0, MAX_POINTS))
	w.raw_bytes(line.get("pd", PackedByteArray()))
	w.raw_bytes(line.get("wd", PackedByteArray()))
	var ghost: bool = line.get("gh", false)
	var discovered: bool = line.get("gd", false)
	var flags := 0
	if ghost:
		flags |= 1
	if discovered:
		flags |= 2
	w.u8(flags)
	if ghost:
		w.u8(int(line.get("go", 0)))
		w.u32(int(line.get("gp", 0)))
	return w.data

static func decode_line(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	var out := {
		"id": r.i16(),
		"ct": r.u8(),
		"pid": r.u8(),
		"t": r.u32(),
		"dd": r.i16(),
		"cn": [],
		"pc": 0,
		"pd": PackedByteArray(),
		"wd": PackedByteArray(),
		"gh": false,
		"gd": false,
	}
	var cn_count := r.u8()
	for i in cn_count:
		(out["cn"] as Array).append(r.u16())
	out["pc"] = r.u16()
	out["pd"] = r.raw_bytes()
	out["wd"] = r.raw_bytes()
	var flags := r.u8()
	out["gh"] = (flags & 1) != 0
	out["gd"] = (flags & 2) != 0
	if out["gh"]:
		out["go"] = r.u8()
		out["gp"] = r.u32()
	return out

## Byte cost of a line network dict (for bandwidth accounting).
static func line_bytes(line: Dictionary) -> int:
	var pd: PackedByteArray = line.get("pd", PackedByteArray())
	var wd: PackedByteArray = line.get("wd", PackedByteArray())
	var cn: Array = line.get("cn", [])
	var size := 2 + 1 + 1 + 4 + 2 + 1 + (cn.size() * 2) + 2 + 2 + pd.size() + 2 + wd.size() + 1
	if line.get("gh", false):
		size += 1 + 4
	return size


# ── Snapshot / delta ──────────────────────────────────────────────────────

## Full authoritative state snapshot.
## Layout: magic u16 | version u8 | match_state u8 | round u8 | flags u8 |
##         phase_msec u32 | last_seq u32 | players: u8 count + per player
##         (id u8, host u8, ready u8, score i32, name string) | lines:
##         u16 count + per line (u16 len + encode_line bytes)
static func encode_snapshot(state: Dictionary) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u16(0xC6A7)  # magic "CG" — sanity check on decode
	w.u8(1)        # protocol version
	w.u8(state.get("match_state", 0))
	w.u8(state.get("round", 0))
	w.u8(state.get("flags", 0))
	w.u32(state.get("phase_msec", 0))
	w.u32(state.get("last_seq", 0))
	var players: Array = state.get("players", [])
	w.u8(clampi(players.size(), 0, MAX_PLAYERS))
	for p in players:
		w.u8(int(p.get("id", 0)))
		w.u8(1 if p.get("is_host", false) else 0)
		w.u8(1 if p.get("ready", false) else 0)
		w.i32(int(p.get("score", 0)))
		w.string(str(p.get("name", "")))
	var lines: Array = state.get("lines", [])
	w.u16(clampi(lines.size(), 0, MAX_LINES))
	for l in lines:
		w.raw_bytes(encode_line(l))
	return w.data

static func decode_snapshot(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	if r.u16() != 0xC6A7:
		return {}
	r.u8()  # version
	var out := {
		"match_state": r.u8(),
		"round": r.u8(),
		"flags": r.u8(),
		"phase_msec": r.u32(),
		"last_seq": r.u32(),
		"players": [],
		"lines": [],
	}
	var player_count := r.u8()
	for i in player_count:
		var p := {
			"id": r.u8(),
			"is_host": r.u8() != 0,
			"ready": r.u8() != 0,
			"score": r.i32(),
			"name": r.string(),
		}
		(out["players"] as Array).append(p)
	var line_count := r.u16()
	for i in line_count:
		(out["lines"] as Array).append(decode_line(r.raw_bytes()))
	return out

## Delta-only state update: 0xFF in a field means "unchanged".
## Layout: match_state u8 | round u8 | flags u8 | last_seq u32 |
##         players: u8 count + per player (id u8, mask u8, [ready u8], [score i32], [host u8]) |
##         lines added: u16 count + per line (u16 len + bytes) |
##         lines removed: u16 count + u16 id each
static func encode_state_delta(delta: Dictionary) -> PackedByteArray:
	var w := ByteWriter.new()
	w.u8(delta.get("match_state", 0xFF))
	w.u8(delta.get("round", 0xFF))
	w.u8(delta.get("flags", 0xFF))
	w.u32(delta.get("last_seq", 0))
	var players: Array = delta.get("players", [])
	w.u8(clampi(players.size(), 0, MAX_PLAYERS))
	for p in players:
		w.u8(int(p.get("id", 0)))
		var mask := 0
		if p.has("ready"):
			mask |= 1
		if p.has("score"):
			mask |= 2
		if p.has("is_host"):
			mask |= 4
		w.u8(mask)
		if p.has("ready"):
			w.u8(1 if p.get("ready", false) else 0)
		if p.has("score"):
			w.i32(int(p.get("score", 0)))
		if p.has("is_host"):
			w.u8(1 if p.get("is_host", false) else 0)
	var added: Array = delta.get("lines_added", [])
	w.u16(clampi(added.size(), 0, MAX_LINES))
	for l in added:
		w.raw_bytes(encode_line(l))
	var removed: Array = delta.get("lines_removed", [])
	w.u16(clampi(removed.size(), 0, MAX_LINES))
	for lid in removed:
		w.u16(int(lid))
	return w.data

static func decode_state_delta(payload: PackedByteArray) -> Dictionary:
	var r := ByteReader.new(payload)
	var out := {
		"match_state": r.u8(),
		"round": r.u8(),
		"flags": r.u8(),
		"last_seq": r.u32(),
		"players": [],
		"lines_added": [],
		"lines_removed": [],
	}
	var player_count := r.u8()
	for i in player_count:
		var p := {"id": r.u8()}
		var mask := r.u8()
		if mask & 1:
			p["ready"] = r.u8() != 0
		if mask & 2:
			p["score"] = r.i32()
		if mask & 4:
			p["is_host"] = r.u8() != 0
		(out["players"] as Array).append(p)
	var added_count := r.u16()
	for i in added_count:
		(out["lines_added"] as Array).append(decode_line(r.raw_bytes()))
	var removed_count := r.u16()
	for i in removed_count:
		(out["lines_removed"] as Array).append(r.u16())
	return out


# ── Helpers ───────────────────────────────────────────────────────────────

static func payload_size(msg: PackedByteArray) -> int:
	return msg.size() - ENVELOPE_SIZE

static func type_name(t: int) -> String:
	return MsgType.keys()[t] if t >= 0 and t < MsgType.COUNT else "UNKNOWN(%d)" % t
