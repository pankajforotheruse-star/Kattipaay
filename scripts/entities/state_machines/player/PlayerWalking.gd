# PlayerWalking.gd — Player is moving toward a target position.

class_name PlayerWalking
extends State

var _arrival_threshold: float = 5.0

func enter(_prev: State) -> void:
	print("Player: walking")

func physics_update(delta: float) -> void:
	var player: CharacterBody2D = machine.get_parent()
	# SceneTree is not paused by the match overlay, so explicit physics
	# protection is required for both human and CPU actors in solo play.
	# Preserve the destination so movement resumes naturally on unpause.
	if GameState.solo_vs_cpu and (GameState.current == GameState.State.PAUSED \
			or GameState.get_match_state() == GameState.MatchState.PAUSED):
		player.velocity = Vector2.ZERO
		return

	# Read target from the player's metadata (set by MovementSystem)
	if not player.has_meta("target_position") or not player.has_meta("has_target"):
		machine.transition_to("idle")
		return

	if not player.get_meta("has_target"):
		machine.transition_to("idle")
		return

	var target: Vector2 = player.get_meta("target_position")
	var world := player.get_tree().current_scene
	var navigation := world.get_node_or_null("VillageNavigation") as VillageNavigation if world else null
	var waypoint := target
	if navigation:
		# Both striker and defender use identical obstacle-safe routes.
		var cached: Vector2 = player.get_meta("_nav_goal", Vector2.INF)
		var route: PackedVector2Array = player.get_meta("_nav_route", PackedVector2Array())
		if not cached.is_finite() or cached.distance_to(target) > 4.0:
			route = navigation.find_route(player.global_position, target)
			player.set_meta("_nav_goal", target)
			player.set_meta("_nav_route", route)
		if route.is_empty():
			player.velocity = Vector2.ZERO
			player.set_meta("has_target", false)
			machine.transition_to("idle")
			return
		while not route.is_empty() and \
				player.global_position.distance_to(route[0]) < 13.0:
			route.remove_at(0)
		player.set_meta("_nav_route", route)
		if route.is_empty():
			player.velocity = Vector2.ZERO
			player.set_meta("has_target", false)
			machine.transition_to("idle")
			return
		waypoint = route[0]
	var direction := waypoint - player.global_position
	var distance := direction.length()
	if distance < _arrival_threshold:
		player.velocity = Vector2.ZERO
		player.set_meta("has_target", false)
		machine.transition_to("idle")
		return
	var speed: float = player.get_meta("move_speed", 200.0)
	player.velocity = direction.normalized() * speed
	player.move_and_slide()
