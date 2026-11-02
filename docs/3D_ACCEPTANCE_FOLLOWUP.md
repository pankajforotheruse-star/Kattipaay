# 3D acceptance follow-up — Godot 4.4

## Branch protection
All work targets `feature/chalk-gaon-3d-migration`. Never merge into `main` without explicit owner authorization.

## Previously discovered P0 failures

1. **Four rooftop approaches:** The old map failed actual capsule/ramp ascent (0/4). Ramp positions, ledges and landings were corrected; the strict CharacterBody3D test subsequently passed **4/4** on CI run 41364574662. The test simulates physics movement, not a visual playthrough or proof that the CPU selects/reaches the ramps in real matches.
2. **CPU stuck at spawn / 4 marks:** Navigation was mistakenly sampling live actor colliders and spawn-paint shapes as obstacles. Ignoring the two live bodies and removing decorative marker collision produced real movement, and a 5-second accelerated target-throughput sample improved to 51/81/107/104 actual marks for Easy/Normal/Hard/Nightmare (seed/target dependent). A minimum pace/displacement CI gate exists. This is not an industry-wide benchmark or fair win-rate result.

## Changes in this follow-up

- **Audio parity:** 3D round calls the existing procedural AudioManager for last-five-seconds, coin flip/landing and successful strike cues. Godot headless intentionally suppresses real audio playback; audible timing and volume need real speakers/device tests.
- **Persistence:** Last 3D match result, first searcher, difficulty and surviving scores are saved using the existing SaveManager under `chalk_gaon_3d_latest_result`, without overwriting the 2D save. This is **result history only**. Complete in-progress 3D resume, moving-cover transforms and per-stroke save/load scene reconstruction are not production-ready.
- **Physical cover:** Covers lifted in the draw phase are returned before meeting/search; a new 3D test checks this state and result persistence. Cover movement is still a box/crate prototype and does not implement every leaf pile/brick, exposed underside, carry/throw or robust character-safe replacement.
- **UI:** 3D continues using its own debug HUD, experimental launch and touch button panel. Full match HUD/coin overlay/results/pause/settings/reward/audio feedback parity with original 2D interfaces is **not complete**.
- **Defender:** 3D has basic human-idle follow and CPU pursuit and optional cheating disabled by default. Needs obstacle-aware human follow, realistic pacing, follow distance and supervised-inspection verification at vertical levels.
- **CPU rooftop searching:** Physical ramps and anchor itinerary exist. A test walking the four rooftops with a generic CharacterBody3D passed, but the live CPU controller still needs its own route-completion, roof-search coverage and descent tests.
- **CPU balance:** Different speeds, nearby detection ranges, and strike delays were introduced without omniscient hidden-mark access. Throughput and count bands are tested, **not win-rate competitiveness**. Targets 50–180 are owner/spec recommendations rather than an industry standard.

## Objective game-specific balance release gate

There is **no universal industry-standard win-rate threshold** for this childhood hide-and-find game. Proposed *internal acceptance criteria* for 3D Play vs CPU, subject to owner review:

1. Run ≥100 reproducible complete rounds per difficulty using several fixed human behavior profiles (many exposed decoys, mostly covered marks, rooftop hiding, rapid freehand).
2. Track per round: CPU target/actual count, legal marks, path completion, stuck events, found segments, cover inspections, roof visits, coin outcomes, defender distance, searched unique areas, winner/survivor margins and actual gameplay time.
3. Confirm the target quantity is feasible within 40 seconds without fake mark placement; 95th-percentile stall duration below 2 seconds; every reachable roof accessible and inspected at least sometimes, not via hidden-coordinate shortcuts.
4. Require monotonically improving CPU search capability from Easy through Nightmare, while monitoring player experience rather than imposing arbitrary overall 50/50 match results. Set per-difficulty win-rate bands only after authentic human playtests.
5. Retest with 100+ human-created marks and dense cover to expose bad visibility and memory scaling; keep cheating disabled by default.

## Android usability and performance test plan (needed before release)

| Dimension | Required on-device evaluation | Suggested initial acceptance target |
|---|---|---|
| Android compatibility | Real phones from Android 8 upward, different GPUs/RAM and aspect ratios; verify export signing and startup | No startup errors or unsupported shaders |
| Touch movement | Two-thumb walk, sprint, orbit, jump, crouch; gesture priority when drawing | No lost touches; no involuntary camera motion while drawing |
| Drawing | Wall/roof/floor/underside strokes; fast/slow drag; multi-finger accidental input; no off-surface marks | Every valid stroke survives and is undoable; 100+ marks persist |
| Covers | Tap/lift, draw beneath, replace; physical reach, collision, accidental double-taps | Inspect only when close; cover returns safely |
| HUD/audio | Coin call, warning cues, score display, pause/results, volume and accessibility | Readable touch targets / audible cues on low-end devices |
| Graphics/performance | 30-minute native session, both territories, multiple roofs, 100–300 simultaneous strokes, moving props | Target 60fps on representative mid-tier hardware, stable ≥30fps on entry-class, no crashes/major thermal throttling |
| Frame profiling | Godot profiler: CPU/GPU frame time, draw calls, overdraw, collision and pathfinding | For 60fps target: total frame time ≤16.7ms; for 30fps ≤33.3ms |
| Memory/performance | Track memory, loading, repeated rounds, background/foreground and power/temperature | Memory stays under real device limits; no frame-time spikes during drawing |

These targets are engineering starting points, **not measurements achieved so far**. Use actual Godot 4.4 Android exports and representative devices. The 3D debug UI likely needs responsive safe-area sizing and tablet layout; physics and AI may need LOD, instancing, stroke mesh batching, low-frequency cover evaluation and navigation cache optimization.

## Evidence and release decision

CI: https://github.com/pankajforotheruse-star/Kattipaay/actions/workflows/village-graybox.yml

**Do not approve main merge based only on parsing/physics/accelerated simulations.** Full parity, empirical CPU win rates and physical Android playtests remain open acceptance criteria.
