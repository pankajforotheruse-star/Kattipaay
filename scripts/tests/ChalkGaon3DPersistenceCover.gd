extends SceneTree
## Godot 4.4 parity: real cover reset and isolated result persistence.
var faults: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var scene := load("res://scenes/3d/game_world_3d.tscn") as PackedScene
	if scene == null:
		push_error("3D persistence scene missing")
		quit(1)
		return
	var game := scene.instantiate()
	root.add_child(game)
	await physics_frame
	var props := get_nodes_in_group("future_movable_props")
	_check(props.size() >= 2, "Both territories contain physical movable cover")
	if props.size() >= 1:
		var cover := props[0] as RigidBody3D
		_check(cover != null, "Cover uses a real physics body")
		if cover != null:
			game._toggle_cover_body(cover)
			_check(bool(cover.get_meta("cover_lifted", false)), "Cover can be lifted")
			game._advance_phase()
			_check(not bool(cover.get_meta("cover_lifted", false)), "Drawing-to-meeting restores lifted cover")
	game._finish_match()
	var store := root.get_node_or_null("SaveManager")
	_check(store != null, "Original SaveManager autoload is available")
	var saved: Dictionary = store.call("load_local", "chalk_gaon_3d_latest_result", {}) if store != null else {}
	_check(str(saved.get("schema", "")) == "chalk_gaon_3d_result_v1", "3D result stored under isolated schema")
	_check(saved.get("result", "") == game.result, "Result persists accurately")
	_check(int(saved.get("human_survivors", -1)) == 0, "Empty human strokes yield zero survivors")
	_check(int(saved.get("cpu_survivors", -1)) == 0, "Empty CPU strokes yield zero survivors")
	var storage_path := "user://chalk_gaon_3d_latest_result.dat"
	if FileAccess.file_exists(storage_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(storage_path))
	if faults.is_empty():
		print("CHALK_GAON_3D_PERSISTENCE_COVER: PASS")
		quit(0)
	else:
		for item in faults:
			push_error("PERSISTENCE_COVER: " + item)
		quit(1)
func _check(ok: bool, label: String) -> void:
	if not ok:
		faults.append(label)
