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
	else:
		# Leaving a match (3D result hold, or PAUSE -> EXIT TO MAIN MENU) also
		# returns here. Route every non-SPLASH state to the village menu instead
		# of leaving the tree on this bare Node (the gray-screen dead end), and
		# put the top-level state back to MAIN_MENU so the menu's next launch
		# (MAIN_MENU -> PLAYING) is a legal transition.
		if GameState.current != GameState.State.MAIN_MENU:
			GameState.transition(GameState.State.MAIN_MENU)
		if not SceneManager.current_scene().ends_with("home.tscn"):
			SceneManager.go_to("menu/home.tscn")
