# ChalkLine.gd — Data resource representing a single drawn chalk line
# Stores all points, widths, metadata, and handles network serialization.
# Compression: RDP simplification → delta encoding → 16-bit quantization (0.5px precision).
#
# Bandwidth budget: a 200-point raw line (~1600 bytes) compresses to <150 bytes.

class_name ChalkLine
extends Resource

## Chalk type enum — maps to GDD §8 chalk types (MVP: White, Red, Yellow, Ghost).
enum ChalkType {
    WHITE = 0,   ## Default — blocks ghosts, 60s duration
    RED = 1,     ## Offensive — deals 20 dmg/sec + 50% slow, 45s duration
    YELLOW = 2,  ## Utility — reveals shades, blocks phasing, 90s duration
    GHOST = 3,   ## Tactical — invisible ghost-placed lines, infinite duration until discovered
}

## Special duration sentinel for ghost lines: they never decay naturally.
const GHOST_DECAY_SENTINEL := -1.0

## Base line widths by chalk type (pixels). Overridden by speed-based thickness at draw time.
const BASE_WIDTHS := {
    ChalkType.WHITE: 4.0,
    ChalkType.RED: 5.0,
    ChalkType.YELLOW: 3.0,
    ChalkType.GHOST: 3.0,   ## Thin — ghost lines are subtle even when revealed
}

## Decay durations by chalk type (seconds). After this, the line fades and is removed.
## GHOST uses GHOST_DECAY_SENTINEL (-1) meaning infinite — they never decay.
const DECAY_DURATIONS := {
    ChalkType.WHITE: 60.0,
    ChalkType.RED: 45.0,
    ChalkType.YELLOW: 90.0,
    ChalkType.GHOST: GHOST_DECAY_SENTINEL,
}

## Default chalk colors for visual tinting
const CHALK_COLORS := {
    ChalkType.WHITE: Color(0.95, 0.94, 0.88, 1.0),   # Cream white
    ChalkType.RED: Color(0.90, 0.21, 0.21, 1.0),      # Vermillion #E53935
    ChalkType.YELLOW: Color(1.0, 0.70, 0.0, 1.0),     # Saffron #FFB300
    ChalkType.GHOST: Color(0.75, 0.85, 1.0, 0.15),    # Faint ghostly blue, near-invisible
}

## Ghost line color when fully revealed (after discovery).
const GHOST_REVEALED_COLOR := Color(0.45, 0.60, 0.85, 1.0)  # Saturated spectral blue


# --- Properties ---

## Unique line ID. Assigned by server/host. -1 until confirmed.
@export var id: int = -1

## World-space points after Catmull-Rom smoothing (stored at ~8px intervals).
@export var points: Array[Vector2] = []

## Per-point widths in pixels (matched 1:1 with points array).
## Derived from draw speed + chalk type base width.
@export var widths: Array[float] = []

## Chalk type (ChalkType enum value).
@export var chalk_type: int = ChalkType.WHITE

## Entity ID of the player who drew this line.
@export var player_id: int = -1

## Creation timestamp (Time.get_ticks_msec()).
@export var created_at: float = 0.0

## Decay duration in seconds. Copied from DECAY_DURATIONS at creation.
@export var decay_duration: float = 60.0

## IDs of other lines this line connects to (for sealed loop detection).
@export var connected_to: Array[int] = []

# --- Ghost-Specific Properties ---

## Whether this line is a ghost-placed (invisible) chalk line.
@export var is_ghost: bool = false

## Whether this ghost line has been discovered by the searcher player.
@export var is_discovered: bool = false

## Entity ID of the ghost player who placed this line. -1 if not a ghost line.
@export var ghost_owner_id: int = -1

## Timestamp (Time.get_ticks_msec()) when the ghost line was placed.
## Used to determine if discovery falls within the 5-second penalty window.
@export var ghost_placed_at: float = 0.0

# --- Computed Properties ---

## Total Euclidean length of the line (sum of segment lengths).
func get_total_length() -> float:
    var total := 0.0
    for i in range(1, points.size()):
        total += points[i].distance_to(points[i - 1])
    return total

## Seconds remaining before this line expires.
func get_remaining_lifetime() -> float:
    if created_at <= 0.0:
        return decay_duration
    var elapsed := (Time.get_ticks_msec() - created_at) / 1000.0
    return max(0.0, decay_duration - elapsed)

## Whether the line has exceeded its decay duration.
## Ghost lines never expire (infinite duration).
func is_expired() -> bool:
    if is_ghost:
        return false
    return get_remaining_lifetime() <= 0.0

## Get base width for this chalk type.
func get_base_width() -> float:
    return BASE_WIDTHS.get(chalk_type, 4.0)

## Get the chalk color for visual rendering.
## Ghost lines return a faint color pre-discovery, saturated blue post-discovery.
func get_chalk_color() -> Color:
    if is_ghost:
        if is_discovered:
            return GHOST_REVEALED_COLOR
        return CHALK_COLORS[ChalkType.GHOST]
    return CHALK_COLORS.get(chalk_type, Color.WHITE)

# --- Network Serialization ---

## Compress the line into a compact Dictionary for network transmission.
## Target: <500 bytes per line, typically <150 bytes.
##
## Compression pipeline:
##   1. RDP simplification (reduce point count while preserving shape within 2px error)
##   2. Delta encoding (store first point absolute, rest as delta from previous)
##   3. Quantization to 0.5px precision → 16-bit signed integers
##   4. Width compression: scale 0.0-10.0 → uint8 (0-255)
func to_network_dict() -> Dictionary:
    # Step 1: Simplify points with Ramer-Douglas-Peucker (epsilon = 2.0px)
    var simplified := _rdp_simplify(points, 2.0)
    var simplified_widths: Array[float] = []
    if widths.size() == points.size() and simplified.size() > 0:
        # Match widths to simplified points by index mapping
        simplified_widths = _match_widths_to_simplified(points, widths, simplified)

    # Step 2+3: Delta encode + quantize positions
    var pos_data := PackedByteArray()
    if simplified.size() > 0:
        # First point: absolute, quantized
        var first_x := int(round(simplified[0].x * 2.0))  # *2 for 0.5px precision
        var first_y := int(round(simplified[0].y * 2.0))
        pos_data.append_array(_int16_to_bytes(first_x))
        pos_data.append_array(_int16_to_bytes(first_y))

        # Remaining points: delta from previous
        for i in range(1, simplified.size()):
            var dx := int(round((simplified[i].x - simplified[i - 1].x) * 2.0))
            var dy := int(round((simplified[i].y - simplified[i - 1].y) * 2.0))
            pos_data.append_array(_int16_to_bytes(dx))
            pos_data.append_array(_int16_to_bytes(dy))

    # Step 4: Compress widths → uint8 (map 0.0-10.0px to 0-255)
    var width_data := PackedByteArray()
    for w in simplified_widths:
        width_data.append(clampi(int(round(w * 25.5)), 0, 255))

    return {
        "id": id,
        "ct": chalk_type,           # chalk_type (abbreviated key to save bytes)
        "pid": player_id,           # player_id
        "t": int(created_at),       # created_at as int msec
        "dd": decay_duration,       # decay_duration
        "cn": connected_to.duplicate(),  # connected_to
        "pc": simplified.size(),    # point_count (for validation on decode)
        "pd": pos_data,             # position data (PackedByteArray)
        "wd": width_data,           # width data (PackedByteArray)
        # Ghost line fields (only populated for ghost lines, omitted otherwise)
        "gh": is_ghost,             # is_ghost
        "go": ghost_owner_id,       # ghost_owner_id
        "gp": int(ghost_placed_at), # ghost_placed_at (int msec)
        "gd": is_discovered,        # is_discovered
    }
    # Estimated size: ~20 bytes overhead + (simplified_points * 4) + (simplified_points * 1)
    # For 10 simplified points: 20 + 40 + 10 = ~70 bytes. Well under 500.


## Reconstruct a ChalkLine from a network dictionary (called on remote clients).
## Returns a fully populated ChalkLine resource.
func from_network_dict(data: Dictionary) -> void:
    id = data.get("id", -1)
    chalk_type = data.get("ct", ChalkType.WHITE)
    player_id = data.get("pid", -1)
    created_at = float(data.get("t", 0))
    decay_duration = float(data.get("dd", DECAY_DURATIONS[chalk_type]))
    connected_to = data.get("cn", [])
    var point_count: int = data.get("pc", 0)

    # Ghost fields (default to false/empty if not in payload)
    is_ghost = data.get("gh", false)
    ghost_owner_id = data.get("go", -1)
    ghost_placed_at = float(data.get("gp", 0))
    is_discovered = data.get("gd", false)

    # Decode positions
    points.clear()
    widths.clear()
    var pos_data: PackedByteArray = data.get("pd", PackedByteArray())
    var width_data: PackedByteArray = data.get("wd", PackedByteArray())

    if pos_data.size() >= 4:  # At least one point (2 int16s)
        var offset := 0
        # First point: absolute
        var first_x := _bytes_to_int16(pos_data, offset); offset += 2
        var first_y := _bytes_to_int16(pos_data, offset); offset += 2
        points.append(Vector2(float(first_x) / 2.0, float(first_y) / 2.0))

        # Remaining points: deltas
        for _i in range(1, point_count):
            if offset + 4 > pos_data.size():
                break
            var dx := _bytes_to_int16(pos_data, offset); offset += 2
            var dy := _bytes_to_int16(pos_data, offset); offset += 2
            var prev := points[-1]
            points.append(Vector2(prev.x + float(dx) / 2.0, prev.y + float(dy) / 2.0))

    # Decode widths
    for i in range(min(point_count, width_data.size())):
        widths.append(float(width_data[i]) / 25.5)


## Estimate the compressed size in bytes (for bandwidth monitoring).
func estimate_network_size() -> int:
    var d := to_network_dict()
    var total := 0
    total += d["pd"].size() if d.has("pd") else 0
    total += d["wd"].size() if d.has("wd") else 0
    total += 30  # approx dict overhead
    return total


# --- Compression Helpers ---

## Ramer-Douglas-Peucker line simplification.
## Reduces point count while ensuring no point is further than `epsilon` from the simplified line.
static func _rdp_simplify(pts: Array[Vector2], epsilon: float) -> Array[Vector2]:
    if pts.size() < 3:
        return pts.duplicate()

    # Find the point with maximum distance from the line segment (first → last)
    var max_dist := 0.0
    var max_idx := 0
    var line_start := pts[0]
    var line_end := pts[-1]
    var line_vec := line_end - line_start
    var line_len_sq := line_vec.length_squared()

    for i in range(1, pts.size() - 1):
        var dist: float
        if line_len_sq < 0.0001:
            dist = pts[i].distance_to(line_start)
        else:
            # Perpendicular distance from point to line segment
            var t := clampf((pts[i] - line_start).dot(line_vec) / line_len_sq, 0.0, 1.0)
            var projection := line_start + line_vec * t
            dist = pts[i].distance_to(projection)
        if dist > max_dist:
            max_dist = dist
            max_idx = i

    # If max distance > epsilon, recursively simplify
    if max_dist > epsilon:
        var left := _rdp_simplify(pts.slice(0, max_idx + 1), epsilon)
        var right := _rdp_simplify(pts.slice(max_idx, pts.size()), epsilon)
        # Merge: remove duplicate at junction
        var result: Array[Vector2] = []
        result.append_array(left)
        for j in range(1, right.size()):
            result.append(right[j])
        return result

    # All points within epsilon → just keep endpoints
    return [pts[0], pts[-1]]


## Match widths from original point array to simplified point array.
static func _match_widths_to_simplified(orig_pts: Array[Vector2], orig_w: Array[float], simp_pts: Array[Vector2]) -> Array[float]:
    var result: Array[float] = []
    for sp in simp_pts:
        # Find closest original point
        var best_idx := 0
        var best_dist := INF
        for i in range(orig_pts.size()):
            var d := sp.distance_squared_to(orig_pts[i])
            if d < best_dist:
                best_dist = d
                best_idx = i
        result.append(orig_w[best_idx] if best_idx < orig_w.size() else 4.0)
    return result


## Convert int16 to 2-byte PackedByteArray (little-endian).
static func _int16_to_bytes(val: int) -> PackedByteArray:
    var clamped := clampi(val, -32768, 32767)
    var bytes := PackedByteArray()
    bytes.append(clamped & 0xFF)
    bytes.append((clamped >> 8) & 0xFF)
    return bytes


## Read int16 from PackedByteArray at offset (little-endian).
static func _bytes_to_int16(data: PackedByteArray, offset: int) -> int:
    var lo := data[offset] if offset < data.size() else 0
    var hi := data[offset + 1] if offset + 1 < data.size() else 0
    var val := lo | (hi << 8)
    if val >= 32768:  # Sign extend
        val -= 65536
    return val
