extends SceneTree
## Server-side authority contract. Does NOT claim an ENet multiplayer lobby.
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var authority := Chalk3DAuthority.new()
	_check(authority.register_server_peer(2, 1), "Host assigns peer 2 human identity")
	_check(not authority.register_server_peer(3, 1), "Cannot duplicate player identity")
	_check(authority.register_server_peer(3, 2), "Host assigns peer 3 CPU-side identity")
	var packed := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	var game := packed.instantiate()
	root.add_child(game)
	await physics_frame
	var packet := {"sequence": 1, "epoch": 0, "action": "strike", "stroke_id": 17}
	_check(not bool(authority.accept(77, packet, game)["accepted"]), "Unregistered peer denied")
	_check(not bool(authority.accept(2, packet, game)["accepted"]), "Cannot strike in drawing phase")
	_check(authority.accept(2, packet, game)["reason"] == "replay_or_out_of_order", "Rejected action sequence cannot replay")
	authority.begin_new_phase()
	_check(authority.accept(2, {"sequence": 2, "epoch": 0, "action": "coin_call", "face": 1}, game)["reason"] == "stale_phase", "Old-phase action denied")
	game.phase = "MEETING"
	_check(bool(authority.accept(2, {"sequence": 3, "epoch": 1, "action": "coin_call", "face": 0}, game)["accepted"]), "Server accepts legitimate coin call")
	_check(game.coin_call == 0, "Server owns resulting coin state")
	_check(not bool(authority.accept(3, {"sequence": 1, "epoch": 1, "action": "coin_call", "face": 1}, game)["accepted"]), "Other owner cannot override coin")
	game.phase = "SEARCHING"
	game.searcher = 1
	authority.begin_new_phase()
	_check(not bool(authority.accept(2, {"sequence": 4, "epoch": 2, "action": "strike", "stroke_id": 99999}, game)["accepted"]), "Cannot strike nonexistent line")
	_check(not bool(authority.accept(2, {"sequence": 5, "epoch": 2, "action": "draw_segment", "start": Vector3(0, 0, 0), "end": Vector3(1, 0, 0)}, game)["accepted"]), "Cannot draw outside drawing phase")
	_check(not bool(authority.accept(2, {"sequence": 6, "epoch": 2, "action": "cover_toggle", "cover_instance_id": -1}, game)["accepted"]), "Cannot target nonexistent cover")
	_check(authority.accepted_actions == 1 and authority.rejected_actions >= 6, "Authority records accepted/rejected actions")
	authority.remove_peer(2)
	_check(not bool(authority.accept(2, {"sequence": 7, "epoch": 2, "action": "strike", "stroke_id": 1}, game)["accepted"]), "Disconnected peer denied")
	if failures.is_empty():
		print("CHALK_GAON_3D_AUTHORITY: PASS (host validation and replay defense; no network transport)")
		quit(0)
	else:
		for failure in failures:
			push_error("3D_AUTHORITY: " + failure)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
