# Kattipaay MVP — Merge Gate and Test Evidence

**Target:** Godot 4.4 **stable**, Play vs CPU. **Branch:** `fix/mvp-critical-play-vs-cpu`; base `main`. PR #32 is draft and MUST NOT be merged without the owner's explicit approval.

## How to run the automated suite

On every PR targeting main, `.github/workflows/godot.yml` runs independent jobs and a final **needs-based** regression gate:

| Layer | Job / executable | Real pass conditions |
|---|---|---|
| Syntax/import | Static / Parse Check, official Godot 4.4 editor | Nonzero exit, SCRIPT ERROR, Parse Error, fatal/segfault or object leaks fail. |
| Scene resource coverage | Within Static / Parse Check, `MvpSceneAudit.gd` | **Every** committed `.tscn` recursively loads and instantiates; failed/missing scene fails. |
| Unit/property | Deterministic Unit Tests, `MvpUnitSuite.gd` | Boundary geometry, mirrored hiding walls, nearest-point reveal, degenerate lines, chalk roundtrip and malformed packets, survivor win/tie cases, solo point isolation, controlled phase clock and pause. |
| Component | Scene Component and Pause Physics, `MvpComponentSuite.gd` | Spawn real GameWorld actors and systems, reject out-of-phase forged draw input, freeze **both** actual character physics on pause and resume target movement without rewinding match. |
| Integration / E2E / functionality / regression | Kattipaay Playable Smoke Test, `KattipaayPlayableSmokeTest.gd` | Real Home → difficulty → draw → coin → both searches → reveal/scoring/winner → home at **Easy, Normal, Hard and Nightmare**, plus Normal defender sneak/ARGUE pass. Coverage listed below. |
| Security baseline | Security / Permissions / CI Policy, `security_audit.py` | No obvious private keys/tokens, forbidden eval/execute calls, elevated PR permissions, unneeded Android location/Wi-Fi privileges or missing test job dependencies; rejects malformed chalk network packets in Godot tests. |
| Final gate | Regression Check | Runs **only if all other independent jobs succeed**. No longer an empty “green” placeholder. |

Equivalent local checks after importing once:

```sh
godot --headless --path . --editor --quit
godot --headless --path . --script res://scripts/tests/MvpSceneAudit.gd
godot --headless --path . --script res://scripts/tests/MvpUnitSuite.gd
godot --headless --path . --script res://scripts/tests/MvpComponentSuite.gd
godot --headless --path . --script res://scripts/tests/KattipaayPlayableSmokeTest.gd
python3 scripts/tests/security_audit.py
```

The executable must report **4.4 stable**, and every process must exit 0 and print its explicit PASS marker. The full-play smoke intentionally uses shortened 8-second drawing/5-second searches; it does NOT substitute for real-duration acceptance.

## Functional and regression matrix

| Feature and failure mode | Automated gate | Extra manual evidence |
|---|---|---|
| Boot, home controls, solo difficulty selector and return home | Playable smoke + scene audit | Android cold/warm launches |
| CPU four difficulty levels; 8/12/16/20 base hidden strokes | Four-difficulty playable smoke | Subjective balance across 10+ random seeds |
| Zone boundaries and player/CPU/alley geometry | Unit + component + smoke | Touch corners and screen-edge scrolling |
| Smooth chalk vs accidental 7px mark and remote draw injection | Smoke + component | Slow, rapid, diagonal, loop, multitouch drawing |
| Walls line up with shared concealment rectangles | Unit + smoke | Check actual rendered art on phone |
| Open-ground/wall reveal distances identical for both sides | Unit + smoke | Probe boundaries visually with camera movement |
| CPU not omniscient, no remote detection/strike; sweep route from public map | Smoke + unit geometry | Observe CPU against randomly hidden marks |
| Human movement-gated discovery and blind/remote strike rejection | Smoke | Walk, stop, rapidly tap elsewhere |
| Both search phases, coin first-searcher, role/zone swaps | All-difficulty smoke | Heads/Tails both outcomes, sound and animation |
| Drawing/search 5-second warnings; timer countdown | Smoke | Real 40s/30s/30s pacing and countdown audio |
| Pause/resume freezes physical CPU + human, search, fog, timers, score and HUD | Unit + component + smoke | System background, lock/unlock, app focus, interrupt calls |
| Human defender ARGUE cap and CPU defender ARGUE role | Smoke | Distract timing and perceived responsiveness |
| Human/CPU sneak, catch penalty, off-path survivors | Smoke | Test 0/1/3 sneaks, simultaneous marks and different sites |
| Invalid/truncated/huge chalk packets cannot mutate active stores | Unit + smoke | Malicious RPC replay/flood/server-side authorization review |
| Zero lines, surviving count, ties, no PvE bonuses in solo | Unit + smoke | Confirm results clarity and readability |
| Reveal, scoreboard and winner overlays visible before returning home | Smoke | Watch on actual display |
| No stale old PvE accusation/UI/shop/XP presentation | Smoke + scene audit | Navigation accessibility walkthrough |
| Asset loading/syntax after code changes, missing scenes | Full scene audit + Godot import | Exported APK scene transitions |
| Runtime crashes, script errors and object lifetime leaks | CI logs + headless process exits | 20 consecutive device matches and profiling |
| Android manifest permission minimization | Python security audit | Verify exported manifest and Android permission prompts |
| Obvious embedded secrets, unsafe process/eval, privileged PR workflows | Security baseline | Independent dependency, RPC, token-storage and pentest review |

## Manual blocking gates — NOT established by green headless CI

These cannot honestly be claimed “passed” from GitHub CI. They must be performed and signed off **before an MVP-complete merge**:

- [ ] **Physical Android release-build run** on supported API 26+ devices, including a modest 2GB-RAM model. Install, offline boot, Home, every difficulty, entire round, winner and repeat after app relaunch.
- [ ] **Real clocks/coin:** timed 40-second draw plus both 30-second searches, five-second audio+visual warnings, correct 50/50 heads/tails behavior across repeated plays, genuine visible reveal/score holds.
- [ ] **Touch/gestures:** one-finger drawing, multi-finger gestures, move/strike interaction, undo, sneak-draw, argue, screen/camera edges, pinch/back/home/foreground, rotation/device aspect ratio, pause/resume during every phase. No unexpected extra strokes on late touch release.
- [ ] **Cover acceptance:** wall and ground, plus the explicitly owner-required **tree shadow and interactively lifted leaf/brick objects**. The latter mechanisms are *not yet implemented* in this branch and are a **known MVP completion blocker**.
- [ ] **Physical obstacle behavior:** verify the intended walkability and cover collision/pathfinding design. Decorative wall art matches concealment coordinates, but no complete obstacle-aware collision/navigation has been implemented.
- [ ] **Balance and fairness:** sample repeated sessions/seeds at Easy/Normal/Hard/Nightmare, confirm CPU cannot learn hidden coordinates, defender sneak risk is fun/fair, no pay-to-win or unexplained loss.
- [ ] **Performance, stability and audio:** profile near 60 FPS, cold-start time, peak memory, battery/heat, no accumulating nodes or audio resources, no crashes across at least 20 complete matches.
- [ ] **Network security (if multiplayer is enabled):** authority on server/host, spoofed IDs, replay, malformed packets, reconnect, room permissions, saved auth tokens, transport TLS, fuzzed large inputs and rate limits. **The baseline scanner does not prove multiplayer safe.** Multiplayer should remain hidden until verified.
- [ ] **Signing and supply chain:** validate SDK/JDK17/keystore handling, APK/AAB export in Godot 4.4, Android manifest, release artifacts, dependency provenance and third-party binary hashes.
- [ ] **UX/accessibility:** tap targets, color contrast, readable counters/warning cues, text overflow, audio-mute operation, input latency, tutorial comprehensibility, game feel.

## Interpretation of security and CI results

“PASS” means the declared automated assertions passed on a GitHub-hosted Linux Godot 4.4 runner, **not** that every runtime state, exploit or hardware combination was tested. Absence of detected embedded secrets is not a proof against runtime token disclosure; heuristic source scanning cannot find every vulnerability. Do not merge solely on the final green regression label; use both the automated suite and the owner's manual completion evidence.

For a safety-critical change to networking, require targeted code review and threat modeling. The current Play vs CPU MVP does not need online authentication.
