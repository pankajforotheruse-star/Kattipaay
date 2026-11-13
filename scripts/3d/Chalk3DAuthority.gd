class_name Chalk3DAuthority
extends RefCounted
## Host-only 3D action gate. Network packets are untrusted proposals, never
## authoritative strikes/marks. No transport is enabled by this class.
## A later ENet integration must assign peer identities on the server.
const MAX_DRAW_SEGMENT := 1.4
const MAX_COVER_REACH := 3.5
var peer_owners: Dictionary = {}
var last_sequences: Dictionary = {}
var phase_epoch := 0
var accepted_actions := 0
var rejected_actions := 0

func register_server_peer(peer_id: int, owner: int) -> bool:
	if peer_id <= 0 or (owner != ChalkMatchRules.HUMAN_ID and owner != ChalkMatchRules.CPU_ID):
		return false
	if peer_owners.has(peer_id):
		return false
	if peer_owners.values().has(owner):
		return false
	peer_owners[peer_id] = owner
	last_sequences[peer_id] = -1
	return true

func remove_peer(peer_id: int) -> void:
	peer_owners.erase(peer_id)
	last_sequences.erase(peer_id)

func begin_new_phase() -> void:
	phase_epoch += 1

func accept(peer_id: int, packet: Dictionary, game: Node3D) -> Dictionary:
	if game == null or not peer_owners.has(peer_id):
		return _reject("unregistered_peer")
	var seq: int = int(packet.get("sequence", -1))
	if seq < 0 or seq <= int(last_sequences.get(peer_id, -1)):
		return _reject("replay_or_out_of_order")
	if int(packet.get("epoch", -1)) != phase_epoch:
		return _reject("stale_phase")
	# Consume sequence before expensive geometry queries, even if denied.
	last_sequences[peer_id] = seq
	var owner: int = int(peer_owners[peer_id])
	var action: String = str(packet.get("action", ""))
	var accepted := false
	match action:
		"coin_call":
			accepted = _coin_call(game, owner, packet)
		"draw_segment":
			accepted = _draw_segment(game, owner, packet)
		"strike":
			accepted = _strike(game, owner, packet)
		"cover_toggle":
			accepted = _cover_toggle(game, owner, packet)
		_:
			return _reject("unknown_action")
	if not accepted:
		return _reject("phase_permission_or_physics")
	accepted_actions += 1
	return {"accepted": true, "sequence": seq, "epoch": phase_epoch}

func _reject(reason: String) -> Dictionary:
	rejected_actions += 1
	return {"accepted": false, "reason": reason}

func _actor(game: Node3D, owner: int) -> CharacterBody3D:
	return game.walker if owner == ChalkMatchRules.HUMAN_ID else game.cpu_body

func _coin_call(game: Node3D, owner: int, packet: Dictionary) -> bool:
	if owner != ChalkMatchRules.HUMAN_ID or game.phase != "MEETING" or game.coin_call >= 0:
		return false
	var call: int = int(packet.get("face", -1))
	if call != 0 and call != 1:
		return false
	game.coin_call = call
	return true

func _draw_segment(game: Node3D, owner: int, packet: Dictionary) -> bool:
	if game.phase != "DRAWING":
		return false
	if not (packet.get("start") is Vector3 and packet.get("end") is Vector3):
		return false
	var start: Vector3 = packet["start"]
	var finish: Vector3 = packet["end"]
	if not start.is_finite() or not finish.is_finite():
		return false
	if start.distance_to(finish) < 0.03 or start.distance_to(finish) > MAX_DRAW_SEGMENT:
		return false
	if not Territory3D.can_draw(owner, start) or not Territory3D.can_draw(owner, finish):
		return false
	var actor := _actor(game, owner)
	if actor == null:
		return false
	var eye := actor.global_position + Vector3.UP * 1.45
	var physics := game.get_world_3d().direct_space_state
	var surface: CollisionObject3D
	var points := PackedVector3Array()
	var normals := PackedVector3Array()
	for proposed in [start, finish]:
		if eye.distance_to(proposed) > ChalkMatchRules.DISCOVERY_DISTANCE_METRES:
			return false
		var query := PhysicsRayQueryParameters3D.create(eye, proposed + (proposed - eye).normalized() * 0.15)
		query.exclude = [actor.get_rid()]
		var hit := physics.intersect_ray(query)
		if hit.is_empty() or (hit["position"] as Vector3).distance_to(proposed) > 0.16:
			return false
		var target := hit.get("collider") as CollisionObject3D
		if target == null or not target.is_in_group("graybox_surfaces"):
			return false
		if surface != null and target != surface:
			return false
		surface = target
		points.append(hit["position"])
		normals.append(hit["normal"])
	if surface == null:
		return false
	var stroke := ChalkStroke3D.new()
	stroke.owner_id = owner
	stroke.stroke_id = game.saved_human_lines.size() + 1 if owner == 1 else game.cpu_lines.size() + 10001
	stroke.surface_id = str(surface.get_path())
	surface.add_child(stroke)
	for i in range(points.size()):
		stroke.add_surface_point(points[i], normals[i])
	if owner == ChalkMatchRules.HUMAN_ID:
		game._human_stroke_created(stroke)
	else:
		game.cpu_lines.append(stroke)
		stroke.visible = false
		game.drawn_cpu_count += 1
	return true

func _strike(game: Node3D, owner: int, packet: Dictionary) -> bool:
	if not ChalkMatchRules.valid_searcher(owner, game.phase, game.searcher):
		return false
	var actor := _actor(game, owner)
	if actor == null:
		return false
	var target_id: int = int(packet.get("stroke_id", -1))
	var opposing: Array = game.cpu_lines if owner == 1 else game.saved_human_lines
	var eye := actor.global_position + Vector3.UP * 1.45
	for stroke in opposing:
		if not is_instance_valid(stroke) or stroke.stroke_id != target_id:
			continue
		if not ChalkMatchRules.can_strike(stroke.owner_id, owner, game.phase, stroke.struck):
			return false
		if not stroke.visible_to_eye(eye, game.get_world_3d().direct_space_state,
				ChalkMatchRules.DISCOVERY_DISTANCE_METRES, actor.get_rid()):
			return false
		stroke.struck = true
		stroke.discovered = true
		stroke.visible = false
		game._actor_pose(owner, "strike")
		game._play_cue("play_line_strike")
		return true
	return false

func _cover_toggle(game: Node3D, owner: int, packet: Dictionary) -> bool:
	if game.phase != "DRAWING" and not ChalkMatchRules.valid_searcher(owner, game.phase, game.searcher):
		return false
	var actor := _actor(game, owner)
	if actor == null:
		return false
	var target_id: int = int(packet.get("cover_instance_id", -1))
	for node in game.get_tree().get_nodes_in_group("future_movable_props"):
		var cover := node as RigidBody3D
		if cover == null or cover.get_instance_id() != target_id:
			continue
		var eye := actor.global_position + Vector3.UP * 1.45
		if eye.distance_to(cover.global_position) > MAX_COVER_REACH:
			return false
		var query := PhysicsRayQueryParameters3D.create(eye, cover.global_position)
		query.exclude = [actor.get_rid()]
		var hit := game.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.get("collider") != cover:
			return false
		var before: bool = bool(cover.get_meta("cover_lifted", false))
		game._toggle_cover_body(cover)
		return bool(cover.get_meta("cover_lifted", false)) != before
	return false
