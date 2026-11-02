# MVP correction register — Godot 4.4 / Play vs CPU

This document tracks the consolidated 13-item audit. The original `main` baseline was
`2e6115b02ca5f8843f61db06459510d6af78c06a` on 2026-11-02. All work is on
`fix/mvp-13-findings-2026-11-02`. **No changes may be merged to main without owner approval.**

Status below describes **implemented candidate fixes**, not completed release acceptance.
A code-level guard, a unit pass and a 2GB Android device acceptance test are different levels
of evidence. Passing Linux CI must not be represented as real-device validation.

| # | Finding | Candidate correction / acceptance |
|---|---|---|
| 1 | Whole-line/multi-object concealment | `ChalkLine.cover_states` stores independent per-site underside bits; symmetric human/CPU visibility and bounded packet decode. Test multi-cover + legacy packets. |
| 2 | Remote/obstructed cover inspection | Shared obstruction-aware `CoverSystem.can_physically_inspect`; test a nominally near cover behind a compound wall. |
| 3 | CPU weighted policy bypass | Active solo anchor sampler chooses actual local decoys, public covers and open spots; never remote marks. Measure policy distribution and sampled mark quotas. |
| 4 | Desktop DRAW emits MOVE | DRAW and MOVE issue distinct events. Reject combined input in component tests. |
| 5 | Final smooth curve escapes hand reach | Revalidate the *finished* spline, not just raw touch vertices; reject illegal curve. |
| 6 | Late/out-of-phase undo | Solo undo allowed only in unpaused DRAWING; verify survivor store is immutable through SEARCHING. |
| 7 | Grid vs exact obstacle reach mismatch | Resolve legal endpoints to non-solid A* cells and check last leg of route; property/fuzz tests for both territories. |
| 8 | Walking stops short | Differentiate intermediate waypoint tolerance from final arrival tolerance. |
| 9 | Meeting/search start before physical arrival | Wait for both actors to reach the alley before coin and for active searcher to reach zone before starting the 30s search; timeout is logged, not silent. |
| 10 | Independent phase clocks | Use `MatchTimer` as the expiry authority; local phase counters remain presentation/diagnostic only. |
| 11 | Missing coin overlay locks round | Fallback resolves coin and advances to SEARCHING after the result hold. |
| 12 | Generic engine ERROR ignored in CI | `check_godot_errors.py` rejects unexpected errors; known upstream Godot 4.4 editor task noise permitted only during import. Investigate/upgrade underlying engine behavior separately. |
| 13 | Legacy implementation/docs drift | Preserve isolated non-solo systems (avoid breaking old code); correct README, document current 2D scope, feature flags, and acceptance limits. |

## Test and release gates

1. Run Godot 4.4 import, scene audit, full deterministic unit, component, playable smoke and security jobs, with no unclassified engine errors. Treat adversarial regression assertions as mandatory.
2. Run **unaccelerated** matches (real 40s draw, 30s each search) for human-first and CPU-first tosses; verify arrival before clocks, pause/resume during arrival, immediate zero-target phase, coin-overlay recovery, and every win/tie condition.
3. Run deterministic navigation fuzzing with obstacles and reach, draw/move input edge cases, serialized multi-cover marks and physical flipping from both directions.
4. Measure CPU decoy/cover/open strategy choices and actual surviving-mark fairness at four difficulties using repeated seeds and human participants. Do not tune raw mark quotas to hide poor strategy.
5. Export and launch a **signed Android** build on supported Android 8+ devices, including a modest ~2GB RAM phone. Check one-finger DRAW/MOVE control, inspection, strike, audio, orientation/background interruptions, crash recovery and 20 consecutive complete matches.
6. Profile CPU, FPS, memory and frame-time for 100, 300, 500 surviving human marks without silently removing marks. Target approximately 60fps; record hardware and actual values.
7. Leave full multiplayer, authentic multiple-child cheating/5-mark penalties and separate 3D migration out of this **2D solo MVP** correction. They require dedicated acceptance gates and explicit authorization.

## Test-only isolation

`chalk_gaon/solo_skip_travel_wait_for_tests` defaults **false** and is enabled only by the accelerated smoke harness. The synthetic smoke test also sets `solo_draw_reach_px=-1`, but the production default is 180px; component tests must separately verify the production reach. A green accelerated match does not certify real physical arrival.

## Known limitations

- The existing headless Godot 4.4 editor-import task errors are still produced by the engine. They are explicitly classified in import logs rather than silently ignored; removing those errors requires a separate root-cause investigation.
- A runtime probe that proves a specific defect has been fixed does not prove all combinations of UI, hardware, networking and physics are correct.
- This branch must remain unmerged until every CI job is green and the owner reviews the remaining Android, balance and performance gates.
