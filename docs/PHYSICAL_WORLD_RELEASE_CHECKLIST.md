# Physical village gameplay: review and release gate

**Status:** Historical release checklist for the physical 2D prototype. The current protected correction branch and remaining gates are recorded in [AUDIT_CORRECTIONS.md](AUDIT_CORRECTIONS.md). **Do not merge any correction branch without explicit owner approval.**

## Owner rules preserved
- Solo human drawing lasts 40 seconds; **NO line quota** and no silent oldest-stroke eviction.
- Every *valid* line must be within the child's avatar's physical **180px arm reach**, on the child's side, and not be drawn through a solid obstacle. This is a reach/validity rule, not a mark-count cap. Player can switch DRAW ↔ MOVE with a visible touch button during the drawing phase.
- CPU chooses a new per-match total from the approved Easy **50–100** range or provisional Normal **65–120**, Hard **85–150**, Nightmare **110–180** ranges, then generates rapid strokes near its **actual roaming avatar position**, while choosing new public destinations every few seconds. CPU arm reach is identical to human's.
- Both searchers physically approach marks and inspected brick/leaf cover; a mark cannot reveal through an opaque wall, house or well. Collidable props and pathfinding read the same visible sprite footprints, and roofs/tree art are tied to canonical hiding sites.
- A line exposed outside its cover remains discoverable at exposed locations; underside chalk requires a local flip. CPU can only set an underside flag after its *own nearby flip action*, otherwise a visible top-surface mark is classified as exposed.
- Defender escort and fair coin/two search clocks/survivor scoring remain intact. The owner's team sneaking + five-line penalty remains explicitly **deferred**.

## Verification
Required CI: Godot 4.4 stable import/parser, all-scene audit, deterministic unit tests (including wall line-of-sight and 100 CPU quota samples per level), component tests (tap-to-move, 500 surviving human lines, remote chalk rejection, CPU physical reach, brick flipping, village collision and accessible hiding sites), full five-match gameplay smoke, security/configuration baseline, final dependent regression gate.

Legacy end-to-end scripted tests place fake human chalk at unrelated map positions to test phase transitions. They deliberately use `chalk_gaon/solo_draw_reach_px=-1` **in that test process only**. The real gameplay default remains **180px**, checked independently in component tests. Do not copy that test override into release settings.

## Important remaining device/experience validation
1. **Physical Android**: test DRAW ↔ MOVE button with real fingers (UI taps never leak into world), walk until arrival after releasing touch, draw near avatar, flip leaves/bricks, inspect during search, and follow the striker. Test Android 8+ release APK and permissions.
2. **Performance**: sample real device memory/FPS while holding 100, 300 and 500 strokes for the full draw + search round. Headless stress checks prove survival, not 60fps; do not silently drop human strokes if performance suffers.
3. **Balance**: have real people play full 40/30/30-second matches at each difficulty and measure win rates / drawn mark counts / discovery counts. The requested CPU mark ranges are much higher than a typical novice's expected count, so balanced outcome is not demonstrated just by quota sampling.
4. **Visual polish and world data**: current 2D procedural characters and public cover sprites are prototypes. Some additional house interactions, animated roof climb and brick handling, and real-world sound cues remain to be artistically refined.
5. **Future scope**: authentic team sneaking and observed five-mark penalties (deferred), full 4–5 children per team, multiplayer security audit and repeated-device network abuse tests.

### Sign-off policy
A green CI status means the code passes the automated gate; it does **not** mean the MVP is guaranteed free of every logical bug, visually finished, physically Android-tested or empirically balanced. The owner must explicitly approve any merge.
