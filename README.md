# Kattipaay — Play vs CPU (Godot 4.4 stable)

Kattipaay is a top-down, mobile-first **draw-and-hide** game inspired by a childhood game. **Play vs CPU** is the development priority. Multiplayer code exists but is not required for the current MVP.

## How to play

1. From Home, select **Play vs CPU** and a difficulty.
2. **Draw (40 seconds):** drag a finger on Android (or hold the left mouse button on desktop) to leave chalk marks in your half of the village. Lines placed along the rendered compound walls are harder to discover.
3. **Meet and toss:** both sides meet at the alley; call heads or tails to determine who searches first.
4. **Search (30 seconds per side):** tap to move your character through the CPU's territory. A mark reveals only when your character reaches its reveal radius. Tap a **discovered** mark nearby to strike it out.
5. **Defend:** while the CPU searches your territory, walk beside the searcher and use the permitted ARGUE/distraction action. The experimental defender sneaking mechanic is **disabled by default** in Play vs CPU; authentic multiplayer cheating penalties are deferred.
6. **Score:** the winner is the side with **more surviving, unstruck lines** after both searches. Equal counts are a draw.

The CPU explores public map geometry rather than seeing the positions of concealed human marks. In the current MVP the game is **2D**; 3D migration is handled separately and is not implemented on `main`.

## Open and test

- Use **Godot 4.4 stable**, not Godot 4.3.
- Open `project.godot` and run the main scene (F5).
- The repository's GitHub Actions **Kattipaay CI — Godot 4.4** workflow imports/parses the project, executes the accelerated end-to-end Play vs CPU smoke test, and gates the regression result.
- Smoke tests cover Normal/Easy rounds, survivor scoring, drawing-phase and search-phase pause/resume, line detection, attempted remote strikes, and human/CPU sneak catches.

The current 2D prototype includes tree-shade classification, visible movable brick/leaf cover, physical reach, collision-aware navigation, and solo CPU searching. These are under active correction/testing, not signed-off Android features. The canonical owner rules are in [docs/CHILDHOOD_MVP_RULES.md](docs/CHILDHOOD_MVP_RULES.md), with the current correction backlog and release gates in [docs/AUDIT_CORRECTIONS.md](docs/AUDIT_CORRECTIONS.md). Physical Android testing, measured CPU balance, performance and full multiplayer verification remain pending.

## Project structure

- `scenes/game/game_world.tscn` — playable world, characters, village props
- `scripts/game/SoloMatchDriver.gd` — draw, meeting, toss, dual searches, reveal, scores and winner state machine
- `scripts/game/HidingRules.gd` — shared wall concealment and discovery distances
- `scripts/systems/DrawSystem.gd` and `GhostDrawSystem.gd` — human and CPU chalk stores
- `scripts/systems/CpuSearchController.gd` — map-based, proximity-gated CPU search
- `scripts/bot/GhostBotController.gd` — CPU line drawing and defending behavior
- `scripts/tests/KattipaayPlayableSmokeTest.gd` — real-scene accelerated end-to-end regression

The older PvE/ghost-accusation designs are not the Play vs CPU game rules.
