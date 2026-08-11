# SceneManager.gd — Handles scene transitions
# Validates against GameState, shows loading curtain if needed.
# Routes both top-level states and match sub-states to their scenes/overlays.

extends Node

var _current_scene_path: String = ""
## Track which match overlay is currently shown (empty string = none).
var _current_match_overlay: String = ""

func _ready() -> void:
	# Listen for state changes to auto-switch scenes
	EventBus.on(EventBus.EV_GAME_STATE_CHANGED, _on_state_changed)
	# Listen for match sub-state changes for overlay routing
	EventBus.on(EventBus.EV_MATCH_STATE_CHANGED, _on_match_state_changed)

## Switch to a new scene (relative to res://scenes/).
func go_to(scene_path: String) -> void:
	var full_path := "res://scenes/" + scene_path
	print("SceneManager: loading %s" % full_path)

	# Remove any match overlay before scene change
	_remove_match_overlay()

	var err := get_tree().change_scene_to_file(full_path)
	if err != OK:
		push_error("SceneManager: failed to load %s (error %d)" % [full_path, err])
		return

	_current_scene_path = full_path
	_current_match_overlay = ""
	EventBus.emit(EventBus.EV_GAME_SCENE_LOADED, {"path": scene_path})

## Reload the current scene.
func reload_current() -> void:
	if _current_scene_path.is_empty():
		return
	_remove_match_overlay()
	get_tree().reload_current_scene()

## Get the current scene's short path.
func current_scene() -> String:
	return _current_scene_path

## Add an overlay scene as a child of the current root (for match sub-states).
## overlay_path is relative to res://scenes/.
func show_overlay(overlay_path: String) -> void:
	if _current_match_overlay == overlay_path:
		return
	_remove_match_overlay()

	var full_path := "res://scenes/" + overlay_path
	var overlay_scene := load(full_path) as PackedScene
	if not overlay_scene:
		push_error("SceneManager: failed to load overlay %s" % full_path)
		return

	var overlay := overlay_scene.instantiate()
	get_tree().root.add_child(overlay)
	_current_match_overlay = overlay_path
	print("SceneManager: overlay shown %s" % overlay_path)

## Remove the current overlay if any.
func remove_overlay() -> void:
	_remove_match_overlay()

func _remove_match_overlay() -> void:
	if _current_match_overlay.is_empty():
		return
	# Find and free overlay nodes that are direct children of root (not the current scene)
	# We track by overlay scene filename — find and free any that match
	for child in get_tree().root.get_children():
		if child is CanvasLayer and child.scene_file_path.ends_with(_current_match_overlay):
			child.queue_free()
		elif child is Control and child.scene_file_path.ends_with(_current_match_overlay):
			child.queue_free()
	print("SceneManager: overlay removed %s" % _current_match_overlay)
	_current_match_overlay = ""

# ── Top-Level State Routing ──────────────────────────────────────────────────

func _on_state_changed(payload: Dictionary) -> void:
	var to: int = payload.get("to", -1)
	match to:
		GameState.State.SPLASH:
			if not _current_scene_path.ends_with("splash.tscn"):
				go_to("menu/splash.tscn")
		GameState.State.MAIN_MENU:
			if not _current_scene_path.ends_with("home.tscn"):
				go_to("menu/home.tscn")
		GameState.State.LOBBY:
			if not _current_scene_path.ends_with("lobby.tscn"):
				go_to("menu/lobby.tscn")
		GameState.State.PLAYING:
			if not _current_scene_path.ends_with("game_world.tscn"):
				go_to("game/game_world.tscn")
		GameState.State.PAUSED:
			# Show pause overlay on top of current scene
			if _current_match_overlay != "overlay/pause.tscn":
				show_overlay("overlay/pause.tscn")
		GameState.State.GAME_OVER:
			if not _current_scene_path.ends_with("game_over.tscn"):
				go_to("game/game_over.tscn")

# ── Match Sub-State Routing ──────────────────────────────────────────────────

func _on_match_state_changed(payload: Dictionary) -> void:
	var to: int = payload.get("to", -1)

	# Remove any previous match overlay (except the one we're about to show)
	_remove_match_overlay()

	match to:
		GameState.MatchState.WAITING:
			# Show loading screen with player names appearing
			show_overlay("overlay/match_waiting.tscn")

		GameState.MatchState.LOBBY:
			# Match-level lobby: loadout, ready-up, chat
			# Could be an overlay or a sub-scene within game_world
			show_overlay("overlay/match_lobby.tscn")

		GameState.MatchState.TEAM_SELECTION:
			show_overlay("overlay/team_selection.tscn")

		GameState.MatchState.DRAWING:
			# Primary gameplay — remove overlays, show game world + HUD
			pass  # HUD is already part of game_world.tscn

		GameState.MatchState.SEARCHING:
			# Fog overlay, limited vision cone, ghost detector
			show_overlay("overlay/searching.tscn")

		GameState.MatchState.REVEAL:
			# Dramatic reveal — brief overlay then clear
			show_overlay("overlay/reveal.tscn")

		GameState.MatchState.SCORING:
			show_overlay("overlay/scoreboard.tscn")

		GameState.MatchState.WINNER:
			show_overlay("overlay/winner.tscn")

		GameState.MatchState.SWAP_TEAMS:
			show_overlay("overlay/swap_teams.tscn")

		GameState.MatchState.RETURN_TO_LOBBY:
			# Brief "Returning to lobby..." overlay
			show_overlay("overlay/returning.tscn")

		GameState.MatchState.PAUSED:
			# Match-level pause overlay
			show_overlay("overlay/pause.tscn")

		GameState.MatchState.NONE:
			# Leaving match — all overlays already removed above
			pass
