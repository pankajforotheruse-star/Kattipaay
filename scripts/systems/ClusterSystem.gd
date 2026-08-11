# ClusterSystem.gd — Detects clusters of ≥5 chalk lines within 50px proximity
#
# Pluggable system: subscribes to EventBus drawing events and detects/updates
# clusters of nearby chalk lines. Clusters are HIDDEN from the player — revealed
# only during scoring.
#
# CORE ALGORITHM:
#   1. Spatial hash (50px grid cells) — O(1) neighbor lookups instead of O(n²)
#   2. Proximity graph (adjacency dict) — lines within PROXIMITY_THRESHOLD (50px)
#   3. BFS connected-component detection — triggered on line add/remove
#   4. Cluster creation when component size ≥ MIN_CLUSTER_SIZE (5)
#   5. Cluster merging when a new component overlaps an existing cluster
#   6. On removal: mark cluster broken, BFS remaining lines for sub-components ≥5
#
# Geometry: minimum segment-to-segment distance for proximity between two
# polylines. Checks intersection (orientation test) first, then falls back to
# point-to-segment distances. Early-exits when a pair is found ≤ threshold.
#
# Subscriptions:
#   - game.line_drawn      → add line to spatial hash, update proximity graph, detect
#   - game.line_removed     → remove from hash/graph, recompute affected clusters
#   - game.line_expired     → same path as line_removed
#   - match.scoring_started → finalize cluster survival/failure status
#
# Emissions:
#   - game.cluster_formed   → analytics only (no visual)
#   - game.cluster_broken   → analytics
#   - game.cluster_survived → scoring phase
#   - game.cluster_failed   → scoring phase

class_name ClusterSystem
extends Node


# --- Constants ---

## Maximum pixel distance between two lines for them to be "nearby."
const PROXIMITY_THRESHOLD := 50.0

## Minimum number of lines required to form a cluster.
const MIN_CLUSTER_SIZE := 5

## Size of each spatial hash cell in pixels. Equal to PROXIMITY_THRESHOLD so
## any line within threshold must lie in the same or adjacent cell.
const SPATIAL_CELL_SIZE := 50.0


# --- Instance State ---

## Lightweight geometry cache: { line_id: {"points": Array[Vector2], "bbox": Rect2} }
var _line_cache: Dictionary = {}

## Spatial hash grid: { "col_row": Array[int] } — cell key → line IDs in that cell.
var _spatial_hash: Dictionary = {}

## Proximity graph adjacency: { line_id: Array[int] } → IDs of nearby lines.
var _proximity_graph: Dictionary = {}

## All clusters (surviving and broken). Managed by create / merge / dissolve.
var _clusters: Array[Cluster] = []

## Auto-incrementing cluster ID counter (never reused within a match).
var _next_cluster_id: int = 0

## Reference to the Systems container node (our parent). Used to find DrawSystem.
var _systems_node: Node = null

## Cached reference to DrawSystem for geometry queries at runtime.
var _draw_system: Node = null


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_systems_node = get_parent()
	if _systems_node:
		_draw_system = _systems_node.get_node_or_null("DrawSystem")

	# --- Subscribe to line lifecycle events ---
	EventBus.on(EventBus.EV_GAME_LINE_DRAWN, _on_line_drawn)
	EventBus.on(EventBus.EV_GAME_LINE_REMOVED, _on_line_removed)
	EventBus.on(EventBus.EV_GAME_LINE_EXPIRED, _on_line_expired)

	# --- Subscribe to match scoring ---
	EventBus.on(EventBus.EV_MATCH_SCORING_STARTED, _on_scoring_started)

	print("ClusterSystem: ready")


func _exit_tree() -> void:
	EventBus.off(EventBus.EV_GAME_LINE_DRAWN, _on_line_drawn)
	EventBus.off(EventBus.EV_GAME_LINE_REMOVED, _on_line_removed)
	EventBus.off(EventBus.EV_GAME_LINE_EXPIRED, _on_line_expired)
	EventBus.off(EventBus.EV_MATCH_SCORING_STARTED, _on_scoring_started)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

## Called when a new chalk line is finalized by DrawSystem.
## payload: {line_id: int, player_id: int, chalk_type: int, point_count: int,
##           compressed_size: int}
func _on_line_drawn(payload: Dictionary) -> void:
	var line_id: int = payload.get("line_id", -1)
	if line_id < 0:
		return

	# --- Fetch geometry from DrawSystem ---
	var line := _find_chalk_line(line_id)
	if not line:
		push_warning("ClusterSystem: line %d not found in DrawSystem" % line_id)
		return

	var points: Array = line.points
	if points.size() < 2:
		# Degenerate line (single point) — cache it but skip proximity checks.
		# Degenerate lines don't participate in clusters.
		_add_to_cache(line_id, points)
		return

	# --- Compute bounding box ---
	var bbox: Rect2 = _compute_bbox(points)

	# --- Store geometry in cache ---
	_add_to_cache(line_id, points, bbox)

	# --- Insert into spatial hash ---
	_spatial_hash_insert(line_id, bbox)

	# --- Find candidate nearby lines via spatial hash ---
	var nearby_ids: Array[int] = []
	_find_nearby_lines(bbox, line_id, nearby_ids)

	# --- Compute exact distances and build proximity edges ---
	for other_id in nearby_ids:
		if other_id == line_id:
			continue
		var other_points: Array = _line_cache[other_id]["points"]
		var dist: float = _minimum_line_distance(points, other_points, PROXIMITY_THRESHOLD)
		if dist <= PROXIMITY_THRESHOLD:
			_add_proximity_edge(line_id, other_id)

	# --- BFS to detect / update clusters ---
	_detect_and_update_clusters(line_id)


## Called when a line is explicitly removed (undo, clear, limit_reached, rejected).
## payload: {line_id: int, reason: String}
func _on_line_removed(payload: Dictionary) -> void:
	var line_id: int = payload.get("line_id", -1)
	var reason: String = payload.get("reason", "unknown")
	_handle_line_removal(line_id, reason)


## Called when a line expires via decay timer.
## payload: {line_id: int}
func _on_line_expired(payload: Dictionary) -> void:
	var line_id: int = payload.get("line_id", -1)
	_handle_line_removal(line_id, "expired")


## Scoring phase started — emit survival/failure for every cluster.
func _on_scoring_started(_payload = null) -> void:
	for cluster in _clusters:
		if cluster.is_surviving:
			EventBus.emit(EventBus.EV_GAME_CLUSTER_SURVIVED, {
				"cluster_id": cluster.cluster_id,
				"line_count": cluster.size(),
				"multiplier": cluster.multiplier,
				"bounds": cluster.get_bounds(),
			})
		else:
			EventBus.emit(EventBus.EV_GAME_CLUSTER_FAILED, {
				"cluster_id": cluster.cluster_id,
				"line_count": cluster.size(),
			})
	print("ClusterSystem: scoring finalized — %d surviving, %d failed" % [
		_count_surviving(), _clusters.size() - _count_surviving()
	])


# =============================================================================
# LINE REMOVAL
# =============================================================================

## Remove a line from all internal structures and repair affected clusters.
func _handle_line_removal(line_id: int, reason: String) -> void:
	if not _line_cache.has(line_id):
		return

	# --- Remove from spatial hash ---
	var bbox: Rect2 = _line_cache[line_id].get("bbox", Rect2())
	_spatial_hash_remove(line_id, bbox)

	# --- Collect clusters that contain this line ---
	var affected_clusters: Array[Cluster] = []
	for cluster in _clusters:
		if cluster.contains_line(line_id):
			affected_clusters.append(cluster)

	# --- Remove from proximity graph ---
	var neighbors: Array = _proximity_graph.get(line_id, [])
	for neighbor_id in neighbors:
		var neighbor_list: Array = _proximity_graph.get(neighbor_id, [])
		var idx := neighbor_list.find(line_id)
		if idx != -1:
			neighbor_list.remove_at(idx)
	_proximity_graph.erase(line_id)

	# --- Remove from geometry cache ---
	_line_cache.erase(line_id)

	# --- Update each affected cluster ---
	for cluster in affected_clusters:
		cluster.is_surviving = false
		var idx := cluster.line_ids.find(line_id)
		if idx != -1:
			cluster.line_ids.remove_at(idx)

		EventBus.emit(EventBus.EV_GAME_CLUSTER_BROKEN, {
			"cluster_id": cluster.cluster_id,
			"reason": reason,
			"removed_line_id": line_id,
		})

		# Attempt to rebuild: BFS remaining lines for sub-components ≥ MIN_CLUSTER_SIZE
		_rebuild_cluster_after_removal(cluster)


# =============================================================================
# CLUSTER DETECTION & MANAGEMENT
# =============================================================================

## Run BFS from a newly added line through the proximity graph.
## If the connected component is ≥ MIN_CLUSTER_SIZE, create or merge clusters.
func _detect_and_update_clusters(new_line_id: int) -> void:
	var component: Array[int] = _bfs_connected_component(new_line_id)

	if component.size() < MIN_CLUSTER_SIZE:
		return  # Proto-cluster — tracked implicitly by proximity graph, no action

	# Check if this component overlaps any existing (surviving) cluster
	var overlapping := _find_overlapping_clusters(component)

	if overlapping.is_empty():
		# Brand new cluster
		var cluster := _create_cluster(component)
		EventBus.emit(EventBus.EV_GAME_CLUSTER_FORMED, {
			"cluster_id": cluster.cluster_id,
			"line_count": cluster.size(),
			"bounds": cluster.get_bounds(),
		})
		print("ClusterSystem: new cluster %d formed — %d lines" % [cluster.cluster_id, cluster.size()])
	else:
		# Merge component into existing cluster(s)
		_merge_clusters(overlapping, component)


## After a line is removed from a cluster, BFS through the remaining line IDs
## to find sub-components that still qualify as clusters. Create replacements
## for any that are ≥ MIN_CLUSTER_SIZE.
func _rebuild_cluster_after_removal(old_cluster: Cluster) -> void:
	var remaining: Array[int] = old_cluster.line_ids.duplicate()
	if remaining.is_empty():
		return  # Cluster fully dissolved

	# BFS from each unvisited remaining line to find connected sub-components
	var visited: Dictionary = {}
	var new_components: Array[Array] = []

	for start_id in remaining:
		if visited.has(start_id):
			continue

		# Constrained BFS: only traverse through remaining line IDs
		var sub_component: Array[int] = []
		var queue: Array[int] = [start_id]

		while not queue.is_empty():
			var current := queue.pop_front()
			if visited.has(current):
				continue
			visited[current] = true
			sub_component.append(current)

			for neighbor_id in _proximity_graph.get(current, []):
				if neighbor_id in remaining and not visited.has(neighbor_id):
					queue.append(neighbor_id)

		if sub_component.size() >= MIN_CLUSTER_SIZE:
			new_components.append(sub_component)

	# Create replacement clusters for qualifying sub-components
	for comp in new_components:
		var new_cluster := _create_cluster(comp)
		EventBus.emit(EventBus.EV_GAME_CLUSTER_FORMED, {
			"cluster_id": new_cluster.cluster_id,
			"line_count": new_cluster.size(),
			"bounds": new_cluster.get_bounds(),
		})
		print("ClusterSystem: replacement cluster %d formed after break — %d lines" % [
			new_cluster.cluster_id, new_cluster.size()
		])


## Find existing surviving clusters whose line_ids intersect the given component.
func _find_overlapping_clusters(component: Array[int]) -> Array[Cluster]:
	var result: Array[Cluster] = []
	for cluster in _clusters:
		if not cluster.is_surviving:
			continue
		for lid in component:
			if cluster.contains_line(lid):
				result.append(cluster)
				break
	return result


## Create a new Cluster data object, register it, and return it.
func _create_cluster(line_ids: Array[int]) -> Cluster:
	var cluster := Cluster.new()
	cluster.cluster_id = _next_cluster_id
	_next_cluster_id += 1
	cluster.line_ids = line_ids.duplicate()
	cluster.is_surviving = true
	cluster.formed_at = Time.get_ticks_msec()
	cluster.bounds = _compute_cluster_bounds(line_ids)
	_clusters.append(cluster)
	return cluster


## Merge multiple overlapping clusters and a new component into the first cluster.
## Absorbed clusters are removed from the registry.
func _merge_clusters(existing: Array[Cluster], new_component: Array[int]) -> void:
	var primary := existing[0]
	var all_ids: Dictionary = {}

	# Collect all line IDs from the primary cluster
	for lid in primary.line_ids:
		all_ids[lid] = true

	# Absorb remaining existing clusters
	for i in range(1, existing.size()):
		var other := existing[i]
		for lid in other.line_ids:
			all_ids[lid] = true
		var idx := _clusters.find(other)
		if idx != -1:
			_clusters.remove_at(idx)

	# Add new component lines
	for lid in new_component:
		all_ids[lid] = true

	# Rebuild primary
	var merged_ids: Array[int] = []
	for lid in all_ids:
		merged_ids.append(lid)

	primary.line_ids = merged_ids
	primary.bounds = _compute_cluster_bounds(merged_ids)

	print("ClusterSystem: merged %d clusters into cluster %d — now %d lines" % [
		existing.size(), primary.cluster_id, primary.size()
	])


# =============================================================================
# SPATIAL HASH
# =============================================================================

## Compute the spatial hash cell key for a world position.
## Returns "col_row", e.g. "3_-2".
static func _spatial_hash_key(pos: Vector2) -> String:
	var col := int(floor(pos.x / SPATIAL_CELL_SIZE))
	var row := int(floor(pos.y / SPATIAL_CELL_SIZE))
	return "%d_%d" % [col, row]


## Insert a line ID into every spatial hash cell overlapping its bounding box.
func _spatial_hash_insert(line_id: int, bbox: Rect2) -> void:
	var min_col := int(floor(bbox.position.x / SPATIAL_CELL_SIZE))
	var max_col := int(floor((bbox.position.x + bbox.size.x) / SPATIAL_CELL_SIZE))
	var min_row := int(floor(bbox.position.y / SPATIAL_CELL_SIZE))
	var max_row := int(floor((bbox.position.y + bbox.size.y) / SPATIAL_CELL_SIZE))

	for col in range(min_col, max_col + 1):
		for row in range(min_row, max_row + 1):
			var key := "%d_%d" % [col, row]
			if not _spatial_hash.has(key):
				_spatial_hash[key] = []
			var cell: Array = _spatial_hash[key]
			if line_id not in cell:
				cell.append(line_id)


## Remove a line ID from every spatial hash cell overlapping its bounding box.
func _spatial_hash_remove(line_id: int, bbox: Rect2) -> void:
	if bbox == Rect2():
		# Fallback: scan all cells (shouldn't happen in normal operation)
		for key in _spatial_hash.keys():
			var cell: Array = _spatial_hash[key]
			var idx := cell.find(line_id)
			if idx != -1:
				cell.remove_at(idx)
				if cell.is_empty():
					_spatial_hash.erase(key)
		return

	var min_col := int(floor(bbox.position.x / SPATIAL_CELL_SIZE))
	var max_col := int(floor((bbox.position.x + bbox.size.x) / SPATIAL_CELL_SIZE))
	var min_row := int(floor(bbox.position.y / SPATIAL_CELL_SIZE))
	var max_row := int(floor((bbox.position.y + bbox.size.y) / SPATIAL_CELL_SIZE))

	for col in range(min_col, max_col + 1):
		for row in range(min_row, max_row + 1):
			var key := "%d_%d" % [col, row]
			if _spatial_hash.has(key):
				var cell: Array = _spatial_hash[key]
				var idx := cell.find(line_id)
				if idx != -1:
					cell.remove_at(idx)
					if cell.is_empty():
						_spatial_hash.erase(key)


## Populate out_ids with unique line IDs found in spatial hash cells overlapping bbox.
## Excludes `exclude_id` (the querying line itself).
func _find_nearby_lines(bbox: Rect2, exclude_id: int, out_ids: Array[int]) -> void:
	var seen: Dictionary = {}
	seen[exclude_id] = true

	var min_col := int(floor(bbox.position.x / SPATIAL_CELL_SIZE))
	var max_col := int(floor((bbox.position.x + bbox.size.x) / SPATIAL_CELL_SIZE))
	var min_row := int(floor(bbox.position.y / SPATIAL_CELL_SIZE))
	var max_row := int(floor((bbox.position.y + bbox.size.y) / SPATIAL_CELL_SIZE))

	for col in range(min_col, max_col + 1):
		for row in range(min_row, max_row + 1):
			var key := "%d_%d" % [col, row]
			if _spatial_hash.has(key):
				for lid in _spatial_hash[key]:
					if not seen.has(lid):
						seen[lid] = true
						out_ids.append(lid)


# =============================================================================
# PROXIMITY GRAPH
# =============================================================================

## Add a bidirectional edge between two line IDs in the proximity graph.
func _add_proximity_edge(id_a: int, id_b: int) -> void:
	if not _proximity_graph.has(id_a):
		_proximity_graph[id_a] = []
	var list_a: Array = _proximity_graph[id_a]
	if id_b not in list_a:
		list_a.append(id_b)

	if not _proximity_graph.has(id_b):
		_proximity_graph[id_b] = []
	var list_b: Array = _proximity_graph[id_b]
	if id_a not in list_b:
		list_b.append(id_a)


# =============================================================================
# BFS CONNECTED COMPONENT
# =============================================================================

## Breadth-first search through the proximity graph starting from start_id.
## Returns all line IDs in the connected component (including start_id).
func _bfs_connected_component(start_id: int) -> Array[int]:
	if not _proximity_graph.has(start_id):
		return [start_id]

	var visited: Dictionary = {}
	var result: Array[int] = []
	var queue: Array[int] = [start_id]

	while not queue.is_empty():
		var current := queue.pop_front()
		if visited.has(current):
			continue
		visited[current] = true
		result.append(current)

		for neighbor_id in _proximity_graph.get(current, []):
			if not visited.has(neighbor_id):
				queue.append(neighbor_id)

	return result


# =============================================================================
# CACHE MANAGEMENT
# =============================================================================

## Store line geometry in the internal cache.
func _add_to_cache(line_id: int, points: Array, bbox := Rect2()) -> void:
	if bbox == Rect2() and points.size() > 0:
		bbox = _compute_bbox(points)
	_line_cache[line_id] = {
		"points": points.duplicate(),
		"bbox": bbox,
	}


## Compute the axis-aligned bounding box enclosing all points.
static func _compute_bbox(points: Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_x: float = points[0].x
	var min_y: float = points[0].y
	var max_x: float = points[0].x
	var max_y: float = points[0].y
	for pt in points:
		if pt.x < min_x: min_x = pt.x
		if pt.y < min_y: min_y = pt.y
		if pt.x > max_x: max_x = pt.x
		if pt.y > max_y: max_y = pt.y
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


## Fetch a ChalkLine resource from DrawSystem by ID. Returns null if not found.
func _find_chalk_line(line_id: int):
	if not _draw_system:
		return null
	var active_lines: Array = _draw_system.get_active_lines()
	for line in active_lines:
		if line.id == line_id:
			return line
	return null


# =============================================================================
# GEOMETRY HELPERS (static)
# =============================================================================

## Minimum segment-to-segment distance between two chalk line polylines.
## Iterates all segment pairs. Early-exits when distance ≤ threshold is found.
static func _minimum_line_distance(points_a: Array, points_b: Array, threshold: float) -> float:
	if points_a.is_empty() or points_b.is_empty():
		return INF

	# Single-point degenerate lines: measure point-to-polyline distance
	if points_a.size() == 1:
		return _point_set_to_line_distance(points_a[0], points_b)
	if points_b.size() == 1:
		return _point_set_to_line_distance(points_b[0], points_a)

	var min_dist: float = INF

	for i in range(points_a.size() - 1):
		var a1: Vector2 = points_a[i]
		var a2: Vector2 = points_a[i + 1]
		for j in range(points_b.size() - 1):
			var b1: Vector2 = points_b[j]
			var b2: Vector2 = points_b[j + 1]
			var d: float = _segment_to_segment_distance(a1, a2, b1, b2)
			if d < min_dist:
				min_dist = d
				if min_dist <= threshold:
					return min_dist  # Early exit — already close enough

	return min_dist


## Distance from a single point to the closest point on a polyline.
static func _point_set_to_line_distance(pt: Vector2, line_points: Array) -> float:
	var min_dist: float = INF
	if line_points.size() == 1:
		return pt.distance_to(line_points[0])
	for i in range(line_points.size() - 1):
		var d: float = _point_to_segment_distance(pt, line_points[i], line_points[i + 1])
		if d < min_dist:
			min_dist = d
	return min_dist


## Minimum distance between two line segments in 2D.
## Checks segment intersection first (returns 0.0 if intersecting),
## then the minimum of the 4 endpoint-to-segment distances.
static func _segment_to_segment_distance(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> float:
	if _segments_intersect(a1, a2, b1, b2):
		return 0.0

	return min(
		min(_point_to_segment_distance(a1, b1, b2), _point_to_segment_distance(a2, b1, b2)),
		min(_point_to_segment_distance(b1, a1, a2), _point_to_segment_distance(b2, a1, a2))
	)


## Shortest distance from point p to line segment ab.
## Projects p onto the infinite line through a-b, then clamps to the segment.
static func _point_to_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var ap := p - a
	var ab_len_sq: float = ab.length_squared()

	if ab_len_sq < 0.0001:
		# a and b are effectively the same point
		return ap.length()

	var t: float = clampf(ap.dot(ab) / ab_len_sq, 0.0, 1.0)
	var projection := a + ab * t
	return p.distance_to(projection)


## Check if two 2D line segments intersect using the orientation (cross-product) test.
## Handles general case (straddling) and collinear/endpoint-touching edge cases.
static func _segments_intersect(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> bool:
	var o1: float = _orientation(a1, a2, b1)
	var o2: float = _orientation(a1, a2, b2)
	var o3: float = _orientation(b1, b2, a1)
	var o4: float = _orientation(b1, b2, a2)

	# General case: segments straddle each other
	if o1 * o2 < 0.0 and o3 * o4 < 0.0:
		return true

	# Collinear / endpoint-touching cases
	if o1 == 0.0 and _point_on_segment(a1, a2, b1): return true
	if o2 == 0.0 and _point_on_segment(a1, a2, b2): return true
	if o3 == 0.0 and _point_on_segment(b1, b2, a1): return true
	if o4 == 0.0 and _point_on_segment(b1, b2, a2): return true

	return false


## Orientation test: returns >0 if p→q→r is counter-clockwise,
## <0 if clockwise, 0 if collinear.
static func _orientation(p: Vector2, q: Vector2, r: Vector2) -> float:
	return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)


## Check if point p lies on segment ab (collinear and within bounding box).
static func _point_on_segment(a: Vector2, b: Vector2, p: Vector2) -> bool:
	return (p.x >= min(a.x, b.x) - 0.0001 and p.x <= max(a.x, b.x) + 0.0001 and
			p.y >= min(a.y, b.y) - 0.0001 and p.y <= max(a.y, b.y) + 0.0001)


# =============================================================================
# CLUSTER BOUNDS
# =============================================================================

## Compute the union bounding box of all member lines, expanded by PROXIMITY_THRESHOLD.
func _compute_cluster_bounds(line_ids: Array[int]) -> Rect2:
	if line_ids.is_empty():
		return Rect2()

	var first_bbox: Rect2 = _line_cache[line_ids[0]]["bbox"]
	var min_x: float = first_bbox.position.x
	var min_y: float = first_bbox.position.y
	var max_x: float = first_bbox.position.x + first_bbox.size.x
	var max_y: float = first_bbox.position.y + first_bbox.size.y

	for i in range(1, line_ids.size()):
		var lid: int = line_ids[i]
		if not _line_cache.has(lid):
			continue
		var bb: Rect2 = _line_cache[lid]["bbox"]
		if bb.position.x < min_x: min_x = bb.position.x
		if bb.position.y < min_y: min_y = bb.position.y
		if bb.position.x + bb.size.x > max_x: max_x = bb.position.x + bb.size.x
		if bb.position.y + bb.size.y > max_y: max_y = bb.position.y + bb.size.y

	# Expand by threshold margin (50px on all sides)
	return Rect2(
		min_x - PROXIMITY_THRESHOLD,
		min_y - PROXIMITY_THRESHOLD,
		(max_x - min_x) + PROXIMITY_THRESHOLD * 2.0,
		(max_y - min_y) + PROXIMITY_THRESHOLD * 2.0
	)


# =============================================================================
# PUBLIC API
# =============================================================================

## Return all clusters (surviving and broken).
func get_active_clusters() -> Array[Cluster]:
	return _clusters.duplicate()


## Return only clusters that are still surviving (is_surviving == true).
func get_surviving_clusters() -> Array[Cluster]:
	var result: Array[Cluster] = []
	for cluster in _clusters:
		if cluster.is_surviving:
			result.append(cluster)
	return result


## Check whether a given line ID belongs to any cluster.
func is_line_in_cluster(line_id: int) -> bool:
	for cluster in _clusters:
		if cluster.contains_line(line_id):
			return true
	return false


## Get the score multiplier for a line.
## Returns 1.5 if the line is in a surviving cluster, 1.0 otherwise.
func get_cluster_multiplier(line_id: int) -> float:
	for cluster in _clusters:
		if cluster.is_surviving and cluster.contains_line(line_id):
			return cluster.multiplier
	return 1.0


## Find a cluster by its unique ID. Returns null if not found.
func get_cluster_by_id(cluster_id: int) -> Cluster:
	for cluster in _clusters:
		if cluster.cluster_id == cluster_id:
			return cluster
	return null


# =============================================================================
# UTILITY
# =============================================================================

## Count surviving clusters.
func _count_surviving() -> int:
	var count := 0
	for cluster in _clusters:
		if cluster.is_surviving:
			count += 1
	return count


## Reset all state — clears caches, graph, cluster registry.
## Called on match restart.
func reset() -> void:
	_line_cache.clear()
	_spatial_hash.clear()
	_proximity_graph.clear()
	_clusters.clear()
	_next_cluster_id = 0
	print("ClusterSystem: reset")
