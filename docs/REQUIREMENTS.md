# CHALK GAON: Ghost Lines — Consolidated Requirements

**Version:** 1.2 · **Dates:** 2026-10-09 (v1.0) · 2026-10-11 (v1.1 — owner MVP restatement) · 2026-10-15 (v1.2 — owner locked the hiding-mechanism spec Q1/Q2/Q3; all 10 deviation-audit items mapped to status)
**Status:** Working requirements (consolidated from owner directives, business plan, WORKFLOW.md, meeting-phase-plan.md, and the owner's 2026-10-11 MVP restatement + 2026-10-15 hiding spec)
**Repo:** pankajforotheruse-star/Kattipaay — `/home/team/shared/chalk-gaon-prototype`

> **2026-10-26 owner revision (development branch only):** The user's latest explicit instructions supersede older 50-line caps, fixed 8/12/16/20 CPU targets and MVP sneak-cheating assumptions. In `feat/childhood-authentic-loop`, authoritative updated rules are in [CHILDHOOD_MVP_RULES.md](CHILDHOOD_MVP_RULES.md): unlimited valid human strokes within 40s, randomized CPU ranges, physical brick flipping, defender supervision, per-segment hiding and cheating penalties deferred. The historical items below are retained until this branch is approved; do not treat their old implementation statuses as current.\n\n> This document is the single consolidated statement of what is being built. Where older docs (GDD, README) conflict with it, the rules below are authoritative because they come from the owner's later directives. The owner's 10-item deviation audit (2026-10-15) is tracked in Appendix C with per-item status — do not skip items; each is either closed, in flight, decided, or awaiting an owner decision.

---

## 1. Short Project Summary

**CHALK GAON: Ghost Lines** is a top-down 2D mobile game for Android built in **Godot 4.4-stable**. One player vs the CPU (or two+ players, local/online) each draw chalk lines in their own half of the village, then take turns visiting the other half to track down and strike out the *hidden* lines; the side with more surviving hidden lines wins. It is a childhood **draw-and-hide** game brought to mobile — lines hidden on walls, under leaves, behind bricks — **not** a hidden-role/social-deduction game (owner reframe, deviation audit #2).

- **Who it's for:** players who enjoy short, playful draw-and-hide games on mobile — quick rounds, a few minutes each. **2–6 players per match** (deviation audit #6). MVP is 1-vs-CPU; 2-player local and 3–6 online build on the same core.
- **Money:** none yet — no products, no payments. Candidate models (unvalidated): free with cosmetic unlocks, or premium one-time price.
- **Co-op PvE is DELETED as a direction** (owner 2026-10-15, deviation audit #1): no PvE code ever shipped; the GDD's wave game is retired and gdd.md is slated for rewrite (#10).
- **Current milestone:** MVP VS CPU loop implemented and validated (draw → coin → tap-strike searches → defend (argue + sneak) → score). Timer warnings done (PR #27). **Hiding mechanism (Deviation Fix #3) is the active build** — owner locked the spec (Q1/Q2/Q3); Commit A (wall+ground) in flight, Commits B+C queued, each gated by full validation.

---

## 2. Document Authority (what overrides what)

1. **Owner directives** (this document, business plan, WORKFLOW.md) — highest.
2. **meeting-phase-plan.md** — owner-confirmed R5/R6 MVP design (2026-09-08); superseded where this doc updates it.
3. **gdd.md** — **retired as a build reference** (deviation audit #1/#10); pending rewrite or replacement.
4. **architecture.md / ui-ux-design.md / sound-design-spec.md / animation-list.md / scene-hierarchy.md** — design references; apply where not overridden.
5. **Working notes (meeting-phase-plan, audit-findings, validation reports)** — team hypotheses; they become decisions when folded into the plan or this doc.

**Standing owner rule (2026-09-08):** Play VS CPU MVP is the north star. Any new requirement that deviates from the MVP must **HALT, be flagged, and be confirmed by the owner** before development. MVP first, then Android export. Develop only on explicit go.

---

## 3. Detailed Requirements

### 3.1 Engine & Platform (owner rules — do not drift)

| Item | Requirement |
|---|---|
| Engine | **Godot 4.4-stable only** — exact binary `Godot_v4.4-stable_linux.x86_64` (`4.4.stable.official.4c311cbee`), `config/features=PackedStringArray("4.4","Mobile")`. Never validate/build against 4.4.1+ unless the owner approves. |
| Target platform | Android 8.0+ (API 26+); rendering method `mobile`. |
| Performance target (owner 2026-08-23) | **Small download + fast startup + low memory + stable 60 FPS.** Quality and correctness first; art/village-scene integration must NOT be gated on download size. (Old "APK < 30 MB" is retired. Old GDD "30 FPS on 2 GB devices" is superseded.) |
| Validation gate | **Full-project validation is mandatory**: every scene and every overlay must import/parse with **zero SCRIPT ERROR / Parse Error** on 4.4-stable, plus the playable smoke suite green. Boot-path-only validation is not sufficient. |

### 3.2 Architecture (implemented — maintain)

- **EventBus** pub/sub with 88+ event constants; systems plug in via subscribe/unsubscribe (every `on` must have a matching `off` in `_exit_tree` — leak-free when scenes are revisited).
- **State machine** layer (top-level game state + per-entity state machines).
- **Autoloads:** EventBus, GameState (top/match state), InputManager, ScoringManager, SaveManager, etc. Solo matches driven by **SoloMatchDriver**; systems: DrawSystem, GhostDrawSystem (CPU line-placer), CpuSearchController (CPU sweep), StrikeSystem (tap-strike), ArgumentSystem, FogSystem, HintSystem, MovementSystem, MatchTimer; overlays for meeting/coin, reveal, scoreboard, winner.
- **Code hygiene:** `.gd` files use **tab** indentation (HUD.gd is the one 4-space file, and its **class-level vars sit at column 0** — only function bodies are 4-space) — edits must be byte-preserving (no tab-normalizing editors); feature branches + PRs; full CI (static/parse, playable smoke, regression).

### 3.3 MVP — Play VS CPU "draw & hide" loop (owner-confirmed spec)

**Owner's canonical description (2026-10-11):** two halves of the scene, one for me one for the CPU; I draw as many lines as possible in my half in 35–40s (smooth, seamless, deliberately hard to find); CPU draws simultaneously in its half; both meet at the alley and decide who strikes first (heads/tails or random); winner travels to the opponent's half and strikes out their lines within ~30s; the defender can argue/distract and can sneak-draw new lines — if noticed, the sneak lines at that exact spot PLUS a couple of the defender's lines get struck, while sneaks elsewhere that went unnoticed survive; when time ends, the hidden/unstruck lines are counted as that side's score; roles swap and the same happens in my half; final scores compared → winner.

Round structure: **DRAW → MEETING/COIN → SEARCH #1 → zone+role swap → SEARCH #2 → REVEAL → SCORING → WINNER → home.**

1. **DRAW (35–40s, end warning)** — both sides draw chalk lines **in their own zone**, hidden from the opponent. Default timer 40s (`solo_drawing_seconds=40.0`, within the owner's 35–40s range). **Timer notifications: DONE (PR #27)** — DRAW **and both SEARCH phases** show a visible + audible **"last 5 seconds"** warning (same tone family; smoke-asserted). Lines decay **only during DRAWING** (frozen through MEETING + searches so they survive to scoring). CPU's ghost lines place during DRAWING (must exist before MEETING ends).
2. **MEETING — "The Coin at the Alley"** — drawing locks; both characters walk to a central meeting point. **Player calls HEADS or TAILS**; CPU always takes the opposite side; coin flip (~2s + sound) is **fair-random at every difficulty** (difficulty affects search/sneak/hiding, NOT who searches first). Winner = first searcher. No call within ~8s → auto-randomize (owner: "head/tell method or maybe randomly" — both paths exist). Meeting capped (~15s); input locked except the coin buttons; round never stalls.
3. **SEARCH #1 (30s, live strike-out)** — first searcher (often the player) travels into the opponent's zone and **strikes** discovered lines: tap → visible chalk-wipe removal (animation + sound), struck line removed, remaining-lines counter ticks live.
4. **Zone + role swap** — second search is a *visit*: the CPU (second searcher) travels into the **player's** zone. Zone titles never change; only who visits whose zone changes. Player is present as **defender** and watches the CPU strike their lines live (same visible wipe + counter). Search phase length `solo_search_phase_seconds=30.0`.
5. **Defender actions during SEARCH #2** (when the CPU searches the player's zone; the same rules apply to the CPU as defender during SEARCH #1, per the owner's "same rules like above apply here for me as well"):
   - **ARGUE / distract** — stalls the searcher's strikes (CPU counter-argue muffles the player's taps during the stall; the player's ARGUE button stalls the CPU sweep `solo_argue_stall_seconds=3.0`; visible banner; "ARGUED ✓" after use). **Frequency: currently capped at once per phase (`solo_argue_uses_per_phase=1`) — MVP-vs-backlog + frequency flagged under deviation #4.**
   - **SNEAK** (up to `solo_sneak_max_lines=3`): hidden one-finger sneak-draw during the opponent's search; zone-clamped; sneak meter shown.
   - **NOTICE + PENALTY (owner's exact rule):** if the searcher notices, all lines the defender was trying to sneak at that point of time and at that exact location are struck, PLUS a couple of the defender's lines are auto-struck; sneaks elsewhere that were never noticed are **not** removed. Current implementation approximates: notice rolled when the sweep passes within 170px (per-difficulty chance, see §3.4); penalty = noticed sneak + up to 2 nearest lines within 240px. Nuance vs the owner's exact-location wording is flagged under deviation #4 (tune at playtest).
6. **REVEAL → SCORING** — count **surviving hidden lines per side**. Sneak lines score only as survivors (excluded from the line-drawn bonus); notice-struck lines never count. **Winner = more surviving hidden lines.** Scoreboard → WINNER → RETURN_TO_LOBBY → home.

### 3.4 Difficulty

EASY / NORMAL / HARD / NIGHTMARE. Applies to CPU behaviors ONLY — **never the physics/fairness** (Q3): CPU search speed + accuracy, notice chance, argue tendency, ghost-line placement bias (more wall/object-concealed lines at higher difficulty — §3.11). It must NOT affect coin fairness (first searcher). **The player's reveal radius, line alpha, and controls are constant across all difficulties (owner Q3).** All tier tuning values (notice chances, speeds, bias shares) are **developer-proposed starting points — labeled "AI-proposed"** in code comments and docs; the owner tunes them at playtest (deviation audit #5). Notice table (AI-proposed): `EASY 0.15 / NORMAL 0.35 / HARD 0.60 / NIGHTMARE 0.85`.

### 3.5 UI / UX (implemented + pending)

- Flow: **Splash → Home → Play VS CPU → difficulty picker → GameWorld** → round → back home.
- **HUD:** remaining-lines counter (fed by strike payloads), ARGUE button (visible only while the CPU searches the player's zone), sneak meter, "NOTICED!" banner, argue banner, search banners, live counters in both directions, **last-5s warning on DRAW + both SEARCH phases (done, PR #27)**.
- Home screen's **shop / settings / battle-pass / collection** buttons are currently non-functional chrome — **pending: hide them until they are real** (deviation audit #8); home-screen rework (village scene, real layout) comes after the hiding mechanic.
- Current game visuals are placeholder (red player block / blue CPU block, no village yet). Village art integration is wanted and **not gated on download size** (performance rule). Wall/ground scenery objects for the hiding mechanism use placeholder art for now (Commit A).

### 3.6 Tutorial

The **wordless three-level tutorial** exists but still teaches the retired accuse path. **Pending: re-author for tap-strike + occlusion rules** (deviation audit #9) — sequence after the hiding-mechanism commits land so it can teach the real mechanics.

### 3.7 Save / statistics

Local save/load (SaveManager) persists player statistics across rounds; scoring statistics must persist on RETURN_TO_LOBBY.

### 3.8 Multiplayer (architected — device test pending)

- **2–6 players** (deviation audit #6). **Offline:** WiFi Direct local play (2-player core). **Online:** Nakama server (lobby + room codes, host migration, reconnect, minimal-bandwidth binary protocol, server-authoritative model with client AuthorityGuard). Built per PRs #1–#14 and fixed in the 31-finding campaign; **device testing pending** (Appendix B #5).

### 3.9 Co-op PvE — DELETED (owner 2026-10-15, deviation audit #1)

The GDD's co-op PvE wave game (ghost haunting, chalk wards, power-ups…) is **no longer a direction**. No PvE code ever shipped. gdd.md is slated for rewrite/retirement (#10). The game is the draw-and-hide 1v1 (and 2–6 player) experience only.

### 3.10 Monetization (unvalidated — no revenue)

No products, no payments. Candidate models: free + cosmetic unlocks, or premium one-time. Nothing to sell until the game is playable end-to-end and device-tested.

### 3.11 Hiding & hidden places — SPEC LOCKED (owner Q1/Q2/Q3, 2026-10-15) · Deviation Fix #3 (MVP-critical)

**Q1 — Four hiding spots in three gated commits (each commit MUST pass the full validation gate — import 0 errors + smoke green + CI green — before the next begins):**
- **Commit A (IN FLIGHT): Wall + Ground** — base drawing/occlusion: wall objects + ground surfaces as scenery (visible to both); lines classified open-ground vs wall-concealed; proximity reveal with wall-concealed lines requiring a strictly smaller reveal radius.
- **Commit B (QUEUED): Tree shadow + proximity reveal** — second occlusion type (tree/shadow) + the proximity fade presentation.
- **Commit C (QUEUED): Under-leaf + under-brick (tap-to-move interactive)** — interactive cover objects the searcher must tap to lift/move before lines beneath are revealed.

**Q2 — Visibility & shared rules:** every object (tree, wall, leaf pile, brick, well, hut, charpai) is **visible to both sides from the start**. ONLY the lines are hidden until proximity/interaction reveals them. **Both player and CPU use identical occlusion rules and an identical proximity radius** (single shared constants source; smoke-asserted).

**Q3 — Difficulty affects the CPU, not physics:** (a) at higher difficulty the CPU places **more of its lines behind objects / in shadow** (fewer on open ground); (b) the CPU searches **faster, with higher accuracy, moving around objects to check them**. The player's **reveal radius, line alpha, and controls stay constant** across all difficulties — keeps the game fair and matches the "depending on difficulty" spec.

---

## 4. MVP Definition of Done & Verification

**Done when (owner's spec):**
- Round plays: draw → meeting → coin call → correct first searcher + defender → live strike search (30s, tap-strike) → zone+role swap (argue + sneak + notice-penalty active on both sides) → second live search → count + winner → home; **0 runtime errors on Godot 4.4-stable**.
- Striking visibly removes lines with animation in BOTH searches; remaining-lines counter live.
- **Last-5s timer warning on ALL timed phases (done — PR #27, smoke-asserted).**
- **Hiding mechanism (Commit A/B/C) with Q2 shared rules and Q3 CPU-only difficulty** — hiding mechanic is MVP-critical, NOT post-MVP.
- Full-project 4.4 validation clean; playable via Home → Play VS CPU → difficulty pick.

**Automated verification currently in place:**
- Full import: 0 SCRIPT ERROR / Parse Error (4.4-stable).
- `KattipaayPlayableSmokeTest.gd` — passes covering: full loop both difficulties, human line survival, CPU sweep strike wiring, argue stall + use-cap, sneak notice + penalty, sneak survival, search-phase last-5s warnings (PR #27), plus per-commit occlusion assertions as they land (Commit A: ground/wall reveal radii + shared rules + CPU placement bias).
- GitHub Actions: static/parse check, playable smoke test, regression gate — green on main.

---

## Appendix A — What Has Already Been Fixed (merged + validated)

| When | What | Validation |
|---|---|---|
| PRs #1–#14 | Boot black-screen fix + full 4.4-stable validation; modular systems on EventBus (~88 constants); state machine; scoring; save system; wordless tutorial; **31-finding audit fix campaign**; Android export pipeline; Nakama multiplayer architecture (lobby/room codes, host migration, reconnect, binary protocol, server-authoritative + AuthorityGuard); solo VS CPU mode. | Import 0 errs; smoke green; CI green |
| PR #22 (slice 3) | **R6 live strike-out search** — two search phases (zone+role swap), surviving-lines winner. | CI green |
| PR #23 (audit MAJORs) | MAJOR-1: line decay frozen to DRAWING only. MAJOR-2: EASY ghost lines placed during DRAWING. | CI green |
| PR #24 (slice 4) | **Defender argue + sneak complete** — CPU notice + penalty, argue stall, CPU counter-argue, sneak scoring, HUD banners; lead fix: CpuSearchController now notices mid-phase sneaks (previously dead mechanic). | Import 0 errs; smoke 3/3; CI green |
| Sweep (main `70e452c`, `b377429`) | Complete-codebase error sweep — event-bus leak fixes (GameWorld/LobbyScreen/MatchmakingScreen `_exit_tree`); human defender **ARGUE button** wired in real play; legacy ACCUSE hidden; static audit clean. | CI green on main |
| PR #25 | Consolidated requirements document (v1.0) → `docs/REQUIREMENTS.md`. | Doc-only; CI green |
| PR #26 | REQUIREMENTS v1.1 — owner MVP restatement: missing items (timer warnings, hiding mechanism) + deviations flagged. | Doc-only; CI green |
| PR #27 | **Last-5s warnings for both SEARCH phases** (deviation audit #7 — CLOSED): EventBus events, SoloMatchDriver tick/watch (phase+searcher payload, no double-fire), HUD banner + countdown (role copy), shared audible cue, smoke assertion `SEARCH_PHASE_WARNING_OK` (both phases, ≤5s). Lead fixed a parse error CI caught (HUD class vars at column 0) before merge. | Static/Parse pass; Regression pass; Smoke 1m16s green (`SEARCH_PHASE_WARNING_OK phases=[1,2]`); main @ `4fe0178` |

## Appendix B — What Is Pending

| # | Item | Notes / why pending |
|---|---|---|
| 1 | **Owner hands-on playtest of the full VS CPU loop** | Machine validation is green; the owner's feel-check is the real gate (first KPI). |
| 2 | **Android export + physical device run** | Needs provisioning: Godot 4.4 export templates + Android SDK + JDK17 + keystore. Verify install → splash → home on device. |
| 3 | **Home screen rework** | Village scene, real layout — and **hide shop / battle-pass / collection buttons until real** (deviation audit #8; owner said after the basic game works). |
| 4 | **Tutorial re-author** | Teach tap-strike + occlusion rules (deviation audit #9); sequence after hiding commits so it teaches real mechanics. |
| 5 | **Multiplayer device test** | Nakama online + WiFi Direct offline architected and code-level fixed, never run on devices. |
| 6 | **Village art integration** | Placeholder blocks in-world today; art exists in shared/artwork + spec docs; not gated on download size. |
| 7 | ~~Co-op PvE wave game~~ | **DELETED** (deviation audit #1) — no longer pending. |
| 8 | **Monetization validation** | No revenue yet; model undecided. |
| 9 | **Docs refresh** | README.md still describes the bootstrap demo; **gdd.md rewrite/retirement** (deviation audit #10); audit-findings per-item status. |
| 10 | **Hiding mechanism Commit B** | Tree shadow + proximity reveal (owner Q1) — starts only after Commit A passes full validation. |
| 11 | **Hiding mechanism Commit C** | Under-leaf + under-brick tap-to-move (owner Q1) — starts only after Commit B passes full validation. |
| 12 | **Argue/sneak MVP-vs-backlog confirmation** | Deviation audit #4 — owner to confirm (recommendation: keep both in MVP; tune at playtest). |

## Appendix C — Owner deviation audit (2026-10-15) + open product flags

| Owner item | Status | Detail |
|---|---|---|
| #1 delete co-op PvE | **DECIDED — done in this doc + plan** | No PvE code existed; §3.9 removed direction; GDD rewrite is #10. |
| #2 reframe away from "hidden-role deception" | **DECIDED — done in this doc + plan** | Game is a childhood draw-and-hide game; docs/plan language updated. Game copy in HUD is neutral and unchanged. |
| #3 hiding mechanic (CS-inspired zone/occlusion) | **IN FLIGHT — Commit A delegated** | Spec locked (Q1/Q2/Q3, §3.11); wall+ground first, then B, then C; each gated by full validation. |
| #4 argue/sneak sub-mechanics — MVP vs backlog | **AWAITING owner confirm** | Recommendation: **keep in MVP** (owner's own spec lists them; built + smoke-verified). Sub-flags: argue frequency (now 1/phase — owner note has no limit) and penalty exact semantics (radius vs exact-location) — tune at playtest. Owner to confirm MVP-vs-backlog in one line. |
| #5 difficulty tiers — label values as AI-proposed | **DECIDED — done** | §3.4 + code comments now label all tuning values AI-proposed; owner tunes at playtest. |
| #6 player count → 2–6 | **DECIDED — done in this doc + plan** | §1/§3.8 say 2–6. |
| #7 last-5s timer notification | **CLOSED — PR #27 merged** | Smoke-asserted on both search phases + draw. |
| #8 hide shop/battle-pass/collection buttons | **PENDING** | Folded into home-screen rework (Appendix B #3). |
| #9 re-author tutorial (tap-strike + occlusion) | **PENDING** | Appendix B #4; sequenced after hiding commits. |
| #10 gdd.md freshness | **PENDING docs task** | Appendix B #9; GDD to be rewritten or replaced (PvE retired per #1). |

**Open product flags (from v1.1, now grouped under #4):** argue frequency (1/phase vs unlimited — owner's note doesn't limit it); penalty exact semantics (owner: all sneaks at exact spot + a couple of lines; build: radius-based approximation). Both are playtest-time tuning decisions — recorded here so they are not lost.