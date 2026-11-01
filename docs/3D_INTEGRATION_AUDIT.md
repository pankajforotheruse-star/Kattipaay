# Chalk Gaon — 3D migration work inventory, CS references and acceptance status

**Branch only:** `feature/chalk-gaon-3d-migration`. **Do not merge to `main` without owner approval.** Original 2D gameplay remains in the repository, and an experimental launch button leads to an independent 3D Play vs CPU development scene.

## Implemented so far

### 3D environment and character
- A bounded village with human and CPU territories, separating walls and an accessible connection.
- Four primitive village houses, interiors, ramps and rooftops, parapets, broken walls and alcoves.
- Low shelter, natural cover, raised surfaces, stone steps, tree, bushes, logs, carts, haystacks and crates.
- Physical Godot static geometry with collision shapes; some crates now use `RigidBody3D` and can be pushed, lifted and replaced.
- `CharacterBody3D` explorer, jump/run/crouch, camera ray collision avoidance and third-person perspective.
- Prototype touch joystick/camera and Android on-screen gameplay buttons, plus mouse/keyboard controls.

### 3D chalk drawing and discovery
- Camera raycasts onto collision surfaces (no predefined drawing locations).
- Restricts drawing ownership to correct 3D territories.
- Mesh strokes attached in surface-local coordinates, with owner metadata and serialization.
- Segment-sampled raycast visibility, line-of-sight, depth testing, and reveal then strike workflow.
- Moving a parented physical surface can move its chalk marks; hidden lines below movable cover can be physically exposed and re-covered.
- Human marks are not subject to a fixed 50-line quota in the new 3D controller; memory/performance must still be measured.

### New 3D single-player match (development mode)
- New scene `scenes/3d/game_world_3d.tscn` with standalone 3D match driver.
- Human and physical CPU actors, 40-second default draw, meeting/coin choice, two 30-second search phases, role swap and survivor winner.
- CPU 3D surface candidate discovery from **public geometry**; randomized target mark counts by difficulty per newer owner spec.
- Physical CPU movement on collision-tested ground cells and line-of-sight detection from the actual CPU position.
- CPU defender following and human defender assisted following when idle; basic physical cover inspection.
- Optional legacy sneak/argument prototype code, but cheating defaults to **disabled** as directed in `docs/CHILDHOOD_MVP_RULES.md` on `feat/childhood-authentic-loop`.
- Existing main menu retains the 2D Play vs CPU game and adds an optional clearly experimental 3D launch.

### Testing and isolation
- CI pins exact Godot **4.4 stable**, imports scenes, tests 3D graybox structure, 3D stroke serialization, territory rules, ground graph, 3D phase sequence and accelerated full round.
- CI also executes the original 2D Play vs CPU regression suite.
- No destructive migration of legacy `ChalkLine`, `DrawSystem`, `SoloMatchDriver`, `ScoringManager` or `GameWorld`.
- No merging or main-branch changes.

## Counter-Strike concepts adapted (design reference, NOT reverse-engineered CS source)

| General Counter-Strike idea | Translation to Chalk Gaon |
|---|---|
| Separate spawns and distinctive map sides | Dedicated human/CPU drawing territories and an open transition between them |
| Multiple levels and tactical geometry | Village roofs, interior rooms, ramps, alcoves and elevated drawing opportunities |
| Choke points, loops and bounded routes | Central meeting connection, lanes, perimeter and cover-based exploration |
| Collision-aware movement | Solid walls, rooftops, character capsule, physical crates and camera collision |
| Line of sight / hiding behind geometry | Chalk becomes difficult to see if a real object or wall blocks the view |
| Navigation around physical cover | Ground-level obstacle-aware graph used for CPU exploration |
| Public-map tactical decision-making | CPU picks surfaces and inspection routes from geometry, not hidden human mark coordinates |

**Explicitly NOT imported:** guns, shooting, damage/recoil, grenades, ammunition, cash/economy, kills, bomb planting, competitive match scoring or CS assets. This game is about hiding and finding chalk. No Counter-Strike executable/source binary reverse engineering was conducted; REA was examined only as a toolkit.

## Mandatory outstanding work / release blockers

These remain incomplete, incompletely tested or physically unverified, and must not be claimed complete just because headless CI is green:

1. **Real-time complete round playtest** with both roles, not just accelerated state flow. Human reveal/strike, CPU mark generation reaching its ambitious 50-180 targets in 40 seconds, game pacing and balance require observation and metrics.
2. **CPU roof/ladder/stair navigation:** current `GroundNavigation3D` intentionally covers accessible ground only; explicit vertical transitions and off-mesh climb movement are missing.
3. **Authentic physical cover:** lifted crate is a prototype; small brick/leaf-pile interaction, valid under-face anchors, revert/restore collision safety, persistence of cover state, and CPU searching all covered hiding spots need better implementation and acceptance tests.
4. **Full legacy match parity:** the 3D scene is an independent driver rather than an event-compatible integration of all `SoloMatchDriver` menus, sound, coin animation, pause/resume, rewards and overlays. Not all 2D state machines have been migrated.
5. **CPU competence:** no proven search path coverage, rooftop search, CPU per-difficulty win-rate balancing, or measured behavior reaching the newer randomized mark target counts.
6. **Android performance/usability:** real device gesture/camera conflicts, touch targets, viewport scaling, memory for hundreds of stroke meshes, render cost, startup and stable 60fps are not device-tested.
7. **Persistence/multiplayer:** stroke versioned serialization exists, but complete save/resume of a match, surface identity across scene reconstruction, 3D network synchronization and reconnection are not verified.
8. **Movement and detection edge cases:** clipping into movable objects, stuck points, human auto-follow around obstacles, underside drawing, thin surface geometry, and every roof/ramp need gameplay validation.
9. **No validated manual visual walkthrough** of the village, CPU search or player drawing. Headless tests cannot substitute.
10. **Owner rule reconciliation** with unmerged `feat/childhood-authentic-loop`; after this branch is reviewed, decide how to integrate existing changes without merging either unapproved branch directly into main.

## Run locally

- Godot 4.4 stable exact version specified in project docs.
- Launch main scene and use **PLAY VS CPU — 3D TEST**, or open `scenes/3d/game_world_3d.tscn` and press F6.
- WASD movement, mouse look, Space jump, Shift run, C crouch, F draw mode, E reveal/strike or inspect cover, Q argue if applicable, H/T call coin. Touch controls available on compatible mobile platforms.
- Inspect both territories, climb ramps, place chalk on varied surfaces, lift and replace crates, observe CPU search, ensure lines only reveal with physical sight, run at normal 40/30/30 timings and check scoring.

## Evidence policy

Only claim successful Godot 4.4 compilation, runtime sanity or regression for exact commits whose GitHub Actions workflow reports success. Do not infer status for newer commits from older green runs. Consult latest run:
https://github.com/pankajforotheruse-star/Kattipaay/actions/workflows/village-graybox.yml

**Release decision: NOT READY FOR MAIN.** Changes remain in the feature branch until full parity, automated tests, real-device sanity and explicit owner merge approval.
