# Bootstrap.gd — Bootstrap script for the main scene.
# Loads the splash scene as the initial scene so that autoloads initialize first.
extends Node

func _ready() -> void:
	print("Bootstrap: starting Chalk Gaon")
	# Give autoloads one frame to fully initialize
	await get_tree().process_frame
	# Start the splash sequence — SceneManager routes to menu/splash.tscn
	GameState.transition(GameState.State.SPLASH)
