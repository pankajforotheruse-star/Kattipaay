class_name CpuSurfacePlanner3D
extends RefCounted
## Physics-aware proposal generator; requires a real NavigationAgent3D controller
## to travel to the selected points before any CPU mark can be placed.
## The CPU must not receive hidden human stroke positions.
const PROBE_HEIGHT := 1.35
const PROBE_DISTANCE := 3.0
const GRID_STEP := 2.5

static func collect_candidates(world: World3D, owner_id: int, nav_position: Vector3, scan_radius: float = 12.0) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	var physics := world.direct_space_state
	var directions := [
		Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT,
		Vector3(1, 0, 1).normalized(), Vector3(-1, 0, 1).normalized(),
		Vector3(1, 0, -1).normalized(), Vector3(-1, 0, -1).normalized(),
		Vector3.UP, Vector3.DOWN
	]
	var steps := maxi(1, int(scan_radius / GRID_STEP))
	for x in range(-steps, steps + 1):
		for z in range(-steps, steps + 1):
			var probe := nav_position + Vector3(float(x) * GRID_STEP, PROBE_HEIGHT, float(z) * GRID_STEP)
			if not Territory3D.can_draw(owner_id, probe):
				continue
			for direction in directions:
				var query := PhysicsRayQueryParameters3D.create(probe, probe + direction * PROBE_DISTANCE)
				var hit := physics.intersect_ray(query)
				if hit.is_empty():
					continue
				var collider := hit.get("collider") as CollisionObject3D
				if collider == null or not collider.is_in_group("graybox_surfaces"):
					continue
				var point: Vector3 = hit["position"]
				if not Territory3D.can_draw(owner_id, point):
					continue
				# A surface can be a candidate only when the ray origin and the mark are
				# inside the right zone. Navigation and physical access still need checking.
				var score := _concealment_score(physics, point, hit["normal"], direction)
				candidates.append({"surface": collider, "position": point, "normal": hit["normal"],
					"approach": probe, "concealment": score})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["concealment"]) > float(b["concealment"]))
	return candidates

static func _concealment_score(physics: PhysicsDirectSpaceState3D, point: Vector3, normal: Vector3, direction: Vector3) -> float:
	# Cover is local to candidate point, not a line-wide boolean; never peek
	# at human marks. Score how obstructed this surface is from nearby angles.
	var hidden_views := 0
	var views := 0
	for azimuth in range(8):
		var angle := float(azimuth) * TAU / 8.0
		var sample_eye := point + Vector3(cos(angle) * 6.0, 1.7, sin(angle) * 6.0)
		var query := PhysicsRayQueryParameters3D.create(sample_eye, point)
		var hit := physics.intersect_ray(query)
		views += 1
		if not hit.is_empty() and (hit["position"] as Vector3).distance_to(point) > 0.12:
			hidden_views += 1
	var score := float(hidden_views) / float(maxi(views, 1))
	# Favour varied orientation rather than exclusively obvious facing walls.
	if absf(normal.y) > 0.75:
		score += 0.1
	if direction.y < -0.5:
		score += 0.1
	return score
