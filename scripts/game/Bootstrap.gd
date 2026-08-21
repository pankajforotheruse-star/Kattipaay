# Bootstrap.gd — Bootstrap script for the main scene.
# Loads the splash scene as the initial scene so that autoloads initialize first.
extends Node

func _ready() -> void:
	print("Bootstrap: starting Chalk Gaon")
	# Give autoloads one frame to fully initialize
	await get_tree().process_frame

	# Route to the current top-level state (SPLASH) so SceneManager loads the
	# splash scene. GameState._ready() sets current = SPLASH but never emits the
	# initial EV_GAME_STATE_CHANGED event, so SceneManager would otherwise leave
	# main.tscn as an empty root node (the black/empty boot screen). Kick-starting
	# the route fixes the boot while preserving the state-machine flow: splash's
	# SplashScreen then transitions SPLASH -> MAIN_MENU to reach home.tscn.
	if GameState.current == GameState.State.SPLASH:
		SceneManager.go_to("menu/splash.tscn")
