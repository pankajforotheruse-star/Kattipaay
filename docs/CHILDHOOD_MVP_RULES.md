# Childhood Kattipaay Play vs CPU: owner-directed revision

**Status:** Work on `feat/childhood-authentic-loop` only; `main` not modified. Parent: `feat/fair-cover-search-loop` PR #34. Draft PR #35 is unmerged.

## Non-negotiable owner rules

1. **40s simultaneous hiding/drawing:** the human has NO fixed line quota. Every valid >18px player-drawn chalk mark survives through the search phases, even if that is 60, 100, or 300 in a single clock. The old 50-line cap, automatic eviction and ghost stamina/decay are disabled for solo. Technical memory/performance remain a device test obligation, never silent deletion of earlier marks.
2. **CPU draws varied counts, independently each round:** Easy 50–100 (owner's sample), Normal 65–120, Hard 85–150, Nightmare 110–180 (other ranges proposed by AI). A seeded per-round random target is distributed over the SAME drawing clock. No fixed quota and no post-time magically placed chalk. The pure algorithm lives in `CpuDrawingPolicy.gd`.
3. **Where to draw matters:** both sides can draw open-ground decoys (to waste the striker's time), on/against compound walls, under tree shadows, on accessible low roofs, and behind movable leaf/brick objects. CPU selects only PUBLIC map locations; it does not inspect any hidden human mark to decide placement. Difficulty influences how often it uses covers versus decoys.
4. **Physically flip or lift a brick/leaf pile:** during the human DRAW phase, tap a visible brick/pile to open, draw beneath/on its hidden face, tap again to replace. A line drawn on top of a closed cover carries `hidden_cover_id="surface"` and can be found without flipping. A line drawn under an opened object carries the site's identifier and requires a later searcher to approach and inspect that object. These properties are serialized with the mark.
5. **Partial coverage is not magical whole-line invisibility:** the shared `HidingRules.can_reveal_line` tests actual stroke segments against the local material (open, wall, oval tree shade, roof, lifted brick/leaf). A visible exposed portion can reveal a partially hidden mark; an entirely covered mark stays unseen until the cover is opened.
6. **Both searchers actually travel:** searcher runs around public terrain, explicitly checks hiding objects, walks closer before a strike, and cannot use unseen coordinates. After a real find, CPU announces the successful strike, pauses briefly, and investigates nearby public hiding spots before resuming its varied patrol; the announcement also appears in the human HUD.
7. **Defender follows the striker:** human defender is NOT locked at zone center. They may tap to walk and supervise CPU strikes; assisted following resumes after ~3 seconds without manual input. CPU defender similarly accompanies the human striker. No attacker/defender is teleported to a secretly known line.
8. **The cheating/sneak rule is deferred:** `chalk_gaon/solo_cheating_enabled` defaults to false, so the current MVP does not use unrealistic distance-free sneak drawing or an invented line-removal rule. The existing experimental mechanic is preserved for later team-play design and can be enabled explicitly for legacy regression tests. The owner's future rule: if a striker sees a defender cheating, caught marks are struck plus an additional *five-line score penalty*; it will require observation/line-of-sight and multiple team-member actors to represent the original 4–5-per-team game accurately. THIS IS NOT PRESENTED AS IMPLEMENTED NOW.
9. **Fair winner:** no arcade extras; compare only surviving unstruck marks after both 30s searches. Coin remains fair 50/50, role swap follows the first search, both last-5s warnings stay intact.

## CPU difficulty values (starting points, NOT measured game balance)

| Skill | Per-round random marks | Public-object cover probability | Easy-to-find decoy probability | Search style |
|---|---:|---:|---:|---|
| Easy | 50–100 | 30% | 26% | slower, broad rows, few inspections |
| Normal | 65–120 | 48% | 18% | moderate public-cover probing |
| Hard | 85–150 | 64% | 13% | faster, narrower rows, more local investigation |
| Nightmare | 110–180 | 78% | 9% | fastest, frequent inspections and nearby checks |

Additional existing wall-anchor bias is applied during pair generation. Thus percentages are approximate strategy probabilities, NOT guaranteed percentages of final lines physically concealed. The playtest must check whether the chosen ranges exceed what an average human can draw in 40s. Random seeds change target, location, line shape, decoy mix, route start and inspection successes.

## Known acceptance gaps and limitations

- **Actual compound walls are now solid** for both striker and defender, with a shared Godot 4.4 AStarGrid2D path through accessible inspection approaches. CI verifies routes to every declared public hiding object. However, **houses, roof access, thrown bricks and other scene props still need physical collision/art refinement**; the current interaction is an accessible top-down abstraction, not a final realistic obstacle model.
- Tapping to flip is an accessible top-down abstraction of picking up or turning a brick. Individual 3D brick faces, roof climbing, throwing a brick face-down, authentic animations and touch UX feedback beyond color fade are not yet present.
- Unlimited human mark count is implemented without arbitrary quotas, **not with physically infinite memory**. Android load testing with several hundred strokes and prolonged sessions must establish safe frame-rate/memory behavior. Do not silently drop user marks to meet performance targets.
- The owner deferred cheat penalties (5-mark deduction) and full 4–5-member team surveillance. Existing simple ARGUE/distraction is not a full multi-child interaction system.
- The owner requires hands-on Android 8+ verification: 40/30/30 timing, heads/tails 50/50 outcomes, two search directions, touch drawing/flipping/following, all-line visual persistence, audio announcement and ~60fps on low-memory devices.
- Difficulty count ranges beyond Easy are recommendations only, and no actual human-versus-CPU win-rate balancing has been performed.

## Merge/sanity gate

Godot `4.4.stable.official`: full editor import and all-scene audit; deterministic geometry/visibility/serialization tests; component tests (65 marks, flip/backside, defender follow, solid-wall navigation and reachable approach to all hiding sites); five accelerated full matches with target range assertions; baseline secret/config security scan; all six GitHub CI jobs green. **Headless CI is not a substitute for physical Android playtesting or measured game balance.**

Do not merge draft PR #35 (or PR #34) into main without explicit owner approval.
