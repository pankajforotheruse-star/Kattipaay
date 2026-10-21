# Kattipaay — fair Play vs CPU rules and difficulty profiles

Godot target: **4.4 stable**. Branch `feat/fair-cover-search-loop`. This spec covers the **actual code**, not discarded ghost/accusation prototype features.

## Ordered game loop

1. From Home choose **Play vs CPU** → Easy / Normal / Hard / Nightmare.
2. Two equal-sized territories are visible, separated by the central alley. The owner of each half draws only in that half.
3. Both sides have ~40 seconds to draw as many sufficiently long chalk strokes as practical. Solo human chalk does **not decay or run out**: the old PvE stamina meter, red/yellow powers, circle sealing and timed line expiry are bypassed, so only a legal strike/undo/sneak penalty (or the technical 50-line capacity) removes a valid mark. CPU has an AI-selected target of 8 / 12 / 16 / 20 base strokes by difficulty. Human is capped at the existing 50-line store.
4. Public hiding places appear identically in each territory: open ground, compound walls, two tree shadows, two leaf piles and two loose-brick piles. A stroke's cover comes from its **actual segment intersection** with these places.
5. At time expiry both travel to the alley, where a player calls heads/tails. A 50/50 toss chooses the first searcher.
6. Each search lasts ~30 seconds or ends when all opponent strokes are struck. The other side becomes searcher for phase 2; no new coin toss.
7. Open-ground strokes reveal when the character walks within **160px**. Wall-concealed strokes reveal within **90px**. Tree-shadow strokes reveal within **105px**. Those are **identical for human and CPU**, on every difficulty.
8. A leaf/brick covered line **does not reveal from proximity alone**. The human must travel close enough (within 100px of the site's boundary), then tap the visible leaf/brick region to inspect it. The cover becomes visibly faded/outlined. The CPU must physically enter the same radius and choose to inspect; it cannot inspect from elsewhere or sense the secret line under unvisited cover.
9. After inspection the covered line may reveal only when the searcher is within **100px of the line**. The human taps a discovered line to strike it; the CPU automatically strikes discovered lines after a short reaction pause.
10. The defender can use ARGUE once during a search phase, interrupting the searcher for the configured 3-second window, and draw at most three extra sneak lines. CPU also has a defender sneak action.
11. A sneak attempt is only catchable when the opponent satisfies the same location **and cover-inspection** predicate. CPU may still fail its encounter notice roll according to difficulty. Caught sneak → that attempted stroke plus at most two existing strokes within 240px of the attempt; missed/off-route strokes survive.
12. The winner is whichever side retains more **unstruck strokes** after both searches, with a draw for equal scores. No old PvE bonus/XP points affect the result. Reveal, scores and winner display before returning Home.

## Fair AI difficulty policy (AI-chosen tuning, not user-authored rules)

| Profile | Base strokes in 40s | Search speed | Patrol lane separation | Public-cover visits before sweep | Probability to inspect reached cover | Reaction after strike | Sneak notice chance | Probability of choosing public shaded/covered anchor |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Easy | 8 | 310 px/s | 260px | 2 | 25% | 1.30s | 15% | 15% |
| Normal | 12 | 420 px/s | 210px | 3 | 55% | 0.80s | 35% | 30% |
| Hard | 16 | 470 px/s | 175px | 4 | 80% | 0.55s | 60% | 55% |
| Nightmare | 20 | 510 px/s | 145px | 6 | 95% | 0.35s | 85% | 75% |

Positive `chalk_gaon/cpu_sweep_speed` is a test/tuning override; -1 selects profile speed. The human has the same physical cover choices and sensing distances at every difficulty. **Difficulty never unlocks coordinate omniscience or allows a searcher's avatar to ignore cover.**

## Architectural protection against omniscience

- `HidingRules.can_reveal_line` contains the single symmetric distance/cover visibility predicate.
- `CoverSystem` tracks which public leaf/brick sites have been inspected in the **current** search phase, and validates the character's real position, role and active phase.
- Human `GhostDrawSystem` discovery and `StrikeSystem` checks use that actual cover state. Input taps alone cannot remotely reveal or strike.
- `CpuSearchController` plans a route using only public territory geometry and the current profile; it does not choose waypoints from hidden human line coordinates.
- It senses opponent lines only after an actual physical encounter (cover state + nearest-segment distance), never from a distant map-wide observation.
- The CPU's solo-mode hiding anchor is drawn from public cover / random terrain, **not** the legacy PvE observer's record of the human's drawing position. Legacy callbacks for human drawing centroids, heatmaps, movement samples and guilt/accusations all return immediately in solo mode; they must never cache those coordinates.

## Difference from legacy MVP and known gaps

Replaces fixed generic serpentine search with public-cover stops plus sweep, and bare ground/wall-only radius checks with active cover inspection. Existing online/multiplayer legacy systems are left out of this solo-mode change.

These cover objects are currently **public 2D procedural shapes with a fade when inspected**, not fully animated hand-drawn leaves, brick physics or realistic light/shadow occlusion. Walls do not yet have a complete collision/navigation mesh. These are explicit **art/pathfinding acceptance gaps**, not verified complete by headless CI.

Run the six-job Godot 4.4 Actions workflow and especially the `FAIR_COVER_SYMMETRY_OK`, `FAIR_COVER_INSPECTION_OK`, `FAIR_DIFFICULTY_POLICIES_OK` and all-four-difficulty gameplay PASS markers. Then do actual Android touch and balance playtesting before considering merge.
