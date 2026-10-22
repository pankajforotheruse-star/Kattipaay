# Village graybox map, implementation status, and acceptance report

## Overhead topology (schematic — not a rendered screenshot)

```text
       NORTH (z = -25)             enclosing static perimeter
┌───────────────────────────┬─────────────────────────────┐
│ PLAYER / WEST (x < 0)     │ CPU / EAST (x > 0)          │
│                          │                             │
│  House A + roof          │ House A + roof              │
│   ramp / interior        │ ramp / interior             │
│           Tree   Alcove  │    Alcove    Tree           │
│ Ruined wall + cart       │ Ruined wall + cart          │
│  Raised platform         │ Raised platform             │
│    Crates  / log         │ Crates / log                │
│                          OPEN CENTRAL CROSSING         │
│  Stone / shed / cover    │ Stone / shed / cover        │
│ House B + roof           │ House B + roof              │
│    ramp / interior       │ ramp / interior             │
└───────────────────────────┴─────────────────────────────┘
       SOUTH (z = +25)
```

Map runs roughly x = -54 to +54, z = -25 to +25. Human spawn debug point x = -27; CPU test point x = +27. Each half is roughly 54 × 50 in this implementation (the original 45m recommendation is approximate, not exact). The divider walls leave a central opening. Tab switches debug explorer between zones.

**Environment catalogue per territory:** two U-shaped houses with roofs/parapets/physical access ramps, recess with three sides, broken wall, low shelter, ruined shed, raised platform, tree, bushes, stone, stone steps, crates (including one named movable candidate), log, cart, haystack, perimeter, ground and spawn marker. All are graybox primitives, not final village assets. Geometry is not fully procedural/configurable and room interiors are open-roofed under flat slab; no second-floor room yet.

## Mandatory acceptance gates / status

| Check | Status | Evidence or outstanding work |
|---|---|---|
| Existing game untouched | SOURCE VERIFIED | Separate new scene/scripts; original scene/project.godot unchanged by branch |
| Two distinct terrain zones and debug spawns | IMPLEMENTED / NOT PLAYTESTED | Positions +/-27, central divider and perimeter |
| Four environment pillars | IMPLEMENTED AT GRAYBOX LEVEL / NOT PLAYTESTED | Roofs, occluder props, recess/shed/low shelter, tree/rocks/vegetation |
| Crouch ability | IMPLEMENTED / NOT PLAYTESTED | C key; capsule shrinks and checks stand-up clearance |
| Roof access | NOT TESTED | Ramps are static physics bodies; alignment and transition must be inspected |
| Player walkthrough | NOT TESTED | Requires graphical input and map traversal |
| CPU-zone walkthrough | NOT TESTED | Debug Tab switches zone, no AI participation |
| Movable objects | CANDIDATE ONLY | Static candidate boxes with `future_movable_props` group; no physical object manipulation |
| Drawing surface readiness | STRUCTURAL ONLY | Collision bodies in `graybox_surfaces`; raycast and stroke system not yet ported |
| CPU navigation readiness | PLANNED, NOT IMPLEMENTED | 2D CPU routines cannot traverse this 3D scene; navmesh/off-mesh links belong after approval |
| Phase-specific territory access | NOT IMPLEMENTED | Passage open for exploration; 2D match logic not connected |
| Godot 4.4 import/parse | NOT VERIFIED | CI workflow committed; inspect Actions status to confirm |
| New graybox structure smoke | NOT VERIFIED | Test script committed; inspect Actions status to confirm |
| Existing 2D gameplay regression | NOT VERIFIED | CI workflow committed; inspect Actions status to confirm |
| Visual inspection of village | NOT TESTED | Owner to run local F6 |
| Hidden-location manual assessment | NOT TESTED | Owner to inspect visibility/reachability |

Do not convert IMPLEMENTED/NOT PLAYTESTED to PASS without evidence. The committed `.github/workflows/village-graybox.yml` runs the pinned Godot 4.4 binary when the feature branch is pushed; its execution outcome must be read from GitHub Actions.

## Change list (all feature branch only)

- `scenes/graybox/village_graybox.tscn`
- `scripts/graybox/VillageGraybox.gd`
- `scripts/tests/VillageGrayboxSmokeTest.gd`
- `.github/workflows/village-graybox.yml`
- `docs/3D_VILLAGE_GRAYBOX.md`
- `docs/2D_TO_3D_MIGRATION.md`
- `docs/VILLAGE_GRAYBOX_REPORT.md`

## Owner manual inspection, excluded from coding task

In Godot 4.4 stable, open `scenes/graybox/village_graybox.tscn` and press F6. Walk both territories; enter buildings; attempt rooftop ramps; crouch under the low shelter; test hidden viewpoints; test outer boundary. Do not integrate production drawing or CPU until this gate has been approved.

The map is a **separate prototype**, not a completed fully playable 3D version of Chalk Gaon. Godot 4.4 compatibility is **targeted, not confirmed by runtime execution** until CI passes.
