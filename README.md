# Chalk Gaon: Ghost Lines — Prototype

Godot 4 prototype proving the core architecture patterns:
- **EventBus**: decoupled pub/sub communication
- **State Machine**: idle/walking transitions per entity
- **Click-to-Move**: touch → EventBus → MovementSystem → state machine → movement
- **Multi-entity**: player-controlled (red) + AI patrol (blue)

## Quick Start

1. Open `project.godot` in **Godot 4.3+**
2. Press **F5** to run
3. **Tap/click** anywhere to move the red player
4. The **blue NPC** patrols automatically

## What You'll See

- Dark background with a debug grid (100px squares)
- Red square = your player (tap to move)
- Blue square = AI NPC (auto-patrol)
- HUD showing current game state and player state
- State transitions: "idle" ↔ "walking" as players move/stop

## Architecture at a Glance

```
Tap screen
  → InputManager emits "input.move_start"
    → Player._on_move_command: sets target, emits "input.move_command_world"
      → MovementSystem._on_move_command: applies target to entity
    → Player state machine: idle → walking
      → PlayerWalking.physics_update: move_and_slide toward target
      → On arrival: walking → idle
```

Every mechanic can be added the same way: subscribe to events, never modify existing code.

## Project Structure

```
scripts/autoload/          — Singletons (EventBus, GameState, InputManager, etc.)
scripts/game/state_machines/ — Base State and StateMachine classes
scripts/entities/           — Entity, Player, NPC + state machines
scripts/systems/            — Pluggable gameplay systems (MovementSystem)
scripts/ui/                 — HUD
scenes/                     — .tscn scene files
```

See `/home/team/shared/architecture.md` for the full architecture document.
