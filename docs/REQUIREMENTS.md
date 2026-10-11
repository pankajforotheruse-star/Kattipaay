# CHALK GAON: Ghost Lines — Consolidated Requirements

**Version:** 1.0 · **Date:** 2026-10-09 · **Status:** Working requirements (consolidated from owner directives, business plan, WORKFLOW.md, meeting-phase-plan.md, gdd.md)
**Repo:** pankajforotheruse-star/Kattipaay — `/home/team/shared/chalk-gaon-prototype`

> This document is the single consolidated statement of what is being built. Where older docs (GDD, README) conflict with it, the rules below are authoritative because they come from the owner's later directives. Conflicts are explicitly flagged in Appendix C.

---

## 1. Short Project Summary

**CHALK GAON: Ghost Lines** is a top-down 2D mobile game for Android built in **Godot 4.4-stable**. Players draw chalk lines, then hunt for the opponent's *hidden* chalk lines (ghost lines) and strike them out before the opponent strikes theirs. The **implemented and validated prototype is a hidden-role deception loop played 1-vs-CPU** (draw → meeting/coin → strike search → defend with argue + sneak → score surviving lines → winner). The original GDD's **co-op PvE wave game remains the long-form future target** (`gdd.md`), not the current build.

- **Who it's for:** players who enjoy short, social deception games on mobile — quick rounds, a few minutes each. Solo VS CPU lets one player learn and play without a group. Multiplayer (online + WiFi Direct) is architected for 3–6 players but is not the MVP.
- **Money:** none yet — no products, no payments. Candidate models (unvalidated): free with cosmetic unlocks, or premium one-time price.
- **Current milestone:** the full VS CPU loop is implemented and machine-validated (0 import errors, 3/3 smoke passes, CI green). Next: **owner hands-on playtest**, then **Android export + physical-device run**.

---

## 2. Document Authority (what overrides what)

1. **Owner directives** (this document, business plan, WORKFLOW.md) — highest.
2. **meeting-phase-plan.md** — owner-confirmed R5/R6 MVP design (2026-09-08).
3. **gdd.md** — long-form vision; superseded where it conflicts with (1)/(2) (stale items flagged in Appendix C).
4. **architecture.md / ui-ux-design.md / sound-design-spec.md / animation-list.md / scene-hierarchy.md** — design references; apply where not overridden.
5. **Working notes (meeting-phase-plan, audit-findings, validation reports)** — team hypotheses; they become decisions when folded into the plan or this doc.

**Standing owner rule (2026-09-08):** Play VS CPU MVP is the north star. Any new requirement that deviates from the MVP must **HALT, be flagged, and be confirmed by the owner** before development. MVP first, then Android export. Develop only on explicit go.

---

## 3. Detailed Requirements

### 3.1 Engine & Platform (owner rules — do not drift)

| Item | Requirement |
|---|---|
| Engine | **Godot 4.4-stable only** — exact binary `Godot_v4.4-stable_linux.x86_64` (`4.4.stable.official.4c311cbee`), `config/features=PackedStringArray("4.4","Mobile")`. Never validate/build against 4.4.1+ unless the owner approves. |
| Target platform | Android 8.0+ (API 26+); rendering method `mobile`; portrait/landscape per current project config. |
| Performance target (owner 2026-08-23) | **Small download + fast startup + low memory + stable 60 FPS.** Quality and correctness first; art/village-scene integration must NOT be gated on download size. (Old "APK < 30 MB" is retired. Old GDD "30 FPS on 2 GB devices" is superseded.) |
| Validation gate | **Full-project validation is mandatory**: every scene and every overlay must import/parse with **zero SCRIPT ERROR / Parse Error** on 4.4-stable, plus the playable smoke suite green. Boot-path-only validation is not sufficient. |

### 3.2 Architecture (implemented — maintain)

- **EventBus** pub/sub with 88+ event constants; systems plug in via subscribe/unsubscribe (every `on` must have a matching `off` in `_exit_tree` — leak-free when scenes are revisited).
- **State machine** layer (top-level game state + per-entity state machines).
- **Autoloads:** EventBus, GameState (top/match state), InputManager, ScoringManager, SaveManager, etc. Solo matches driven by **SoloMatchDriver**; systems: DrawSystem, GhostDrawSystem (CPU line-placer), CpuSearchController (CPU sweep), StrikeSystem (tap-strike), ArgumentSystem, FogSystem, HintSystem, MovementSystem, MatchTimer; overlays for meeting/coin, reveal, scoreboard, winner.
- **Code hygiene:** `.gd` files use **tab** indentation (HUD.gd is the one 4-space file) — edits must be byte-preserving (no tab-normalizing editors); feature branches + PRs; full CI (static/parse, playable smoke, regression).

### 3.3 MVP — Play VS CPU deception loop (owner-confirmed spec)

Round structure: **DRAW → MEETING/COIN → SEARCH #1 → zone+role swap → SEARCH #2 → REVEAL → SCORING → WINNER → home.**

1. **DRAW (35–40s + end warning)** — both sides draw chalk lines **in their own zone**, hidden from the opponent. Lines decay **only during DRAWING** (frozen through MEETING + searches so they survive to scoring). EASY CPU places its ghost lines during DRAWING (must exist before MEETING ends).
2. **MEETING — "The Coin at the Alley"** — drawing locks; both characters walk to a central meeting point. **Player calls HEADS or TAILS**; CPU always takes the opposite side; coin flip (~2s + sound) is **fair-random at every difficulty** (difficulty affects search/sneak/hiding, NOT who searches first). Winner = first searcher. Meeting capped (~15s); no call within ~8s → auto-randomize. Input locked except the coin buttons; round never stalls.
3. **SEARCH #1 (30s, live strike-out)** — first searcher (often the player) travels into the opponent's zone and **strikes** discovered lines: tap → visible chalk-wipe removal (animation + sound), struck line removed, remaining-lines counter ticks live.
4. **Zone + role swap** — second search is a *visit*: the CPU (second searcher) travels into the **player's** zone. Zone titles never change; only who visits whose zone changes. Player is present as **defender** and watches the CPU strike their lines live (same visible wipe + counter).
5. **Defender actions during SEARCH #2** (when CPU searches the player's zone):
   - **ARGUE / distract** (once per phase): stalls the CPU sweep (`solo_argue_stall_seconds=3.0`); visible banner; reachable in real play via the **HUD ARGUE button** ("ARGUED ✓" after use). CPU can counter-argue once while it defends (`cpu_argue_chance=0.5`), muffling the player's strikes during the stall.
   - **SNEAK** (up to `solo_sneak_max_lines=3`): one-finger sneak-draw of hidden lines during the CPU's search; zone-clamped; sneak meter shown.
   - **NOTICE + PENALTY:** CPU may notice a sneak when its sweep passes within 170px of it (roll per line once; chance read live per roll; per-difficulty table `EASY 0.15 / NORMAL 0.35 / HARD 0.60 / NIGHTMARE 0.85`; leftover sneaks get one final "circles back" roll at sweep end, ≤1 penalty). On notice: visible "NOTICED!" banner → the sneak line **plus up to 2 nearest defender lines within 240px are struck** (CPU "re-checks" the area). **Unnoticed sneaks survive.**
6. **REVEAL → SCORING** — count **surviving hidden lines per side**. Sneak lines score only as survivors (excluded from the line-drawn bonus); notice-struck lines never count. **Winner = more surviving hidden lines.** Scoreboard → WINNER → RETURN_TO_LOBBY → home.

### 3.4 Difficulty

EASY / NORMAL / HARD / NIGHTMARE. Applies to CPU behaviors (search speed, notice chance, argue tendency, ghost-line hiding). It must NOT affect coin fairness (first searcher).

### 3.5 UI / UX (implemented + pending)

- Flow: **Splash → Home → Play VS CPU → difficulty picker → GameWorld** → round → back home.
- **HUD:** remaining-lines counter (fed by strike payloads), ARGUE button (visible only while the CPU searches the player's zone), sneak meter, "NOTICED!" banner, argue banner, search banners, live counters both directions.
- Home screen also has **shop / settings / battle-pass / collection** buttons — currently **non-functional and mispositioned** (owner: fix the basic game first, then a visually appealing startup/home page with a village scene and real layout).
- Current game visuals are placeholder (red player block / blue CPU block, no village yet). Village art integration is wanted and **not gated on download size** (performance rule).

### 3.6 Tutorial

A **wordless three-level tutorial** exists. Note: the real loop replaced "accuse" with tap-strike; the accusation path survives only as a tutorial shim (see Appendix C, item 4).

### 3.7 Save / statistics

Local save/load (SaveManager) persists player statistics across rounds; scoring statistics must persist on RETURN_TO_LOBBY.

### 3.8 Multiplayer (architected — not MVP, not device-tested)

- **Offline:** WiFi Direct local play. **Online:** Nakama server (lobby + room codes, host migration, reconnect, minimal-bandwidth binary protocol, server-authoritative model with client AuthorityGuard). Built per PRs #1–#14 and fixed in the 31-finding campaign; **device testing pending** (see Appendix B).

### 3.9 Long-form game (future target, GDD)

Co-op PvE wave game: village ghost haunting, chalk wards, ghost types, power-ups, sealing circles, boss — as specified in `gdd.md`. Not in the current build; requires owner go before work.

### 3.10 Monetization (unvalidated — no revenue)

No products, no payments. Candidate models: free + cosmetic unlocks, or premium one-time. Nothing to sell until the game is playable end-to-end and device-tested.

---

## 4. MVP Definition of Done & Verification

**Done when (owner's spec):**
- Round plays: draw → meeting → coin call (player calls, wins → you first / loses → CPU first / timeout → auto-random) → correct first searcher + defender → live strike search (30s) → zone+role swap → second live strike search → count + winner → home; **0 runtime errors on Godot 4.4-stable**.
- Striking visibly removes lines with animation in BOTH searches; remaining-lines counter live.
- Full-project 4.4 validation clean; playable via Home → Play VS CPU → difficulty pick.

**Automated verification currently in place:**
- Full import: 0 SCRIPT ERROR / Parse Error (4.4-stable).
- `KattipaayPlayableSmokeTest.gd` — 3 passes (NORMAL: human-drawn lines survive + CPU sweep strike wiring; EASY: ghost lines exist before MEETING ends; NORMAL slice-4: argue stall + use-cap, sneak noticed at chance 1.0 → penalty, sneak unnoticed at 0.0 → survives into scoring). CI cap 240s.
- GitHub Actions: static/parse check, playable smoke test, regression gate — all green on main.

---

## Appendix A — What Has Already Been Fixed (status: merged + validated)

| When | What | Validation |
|---|---|---|
| PRs #1–#14 | Boot black-screen fix + full 4.4-stable validation; modular systems on EventBus (~88 constants); state machine; scoring; save system; wordless tutorial; **31-finding audit fix campaign** (incl. GhostDrawSystem parse error, HomeScreen nested func, GameState enum misuse, ScoringManager save calls, line-drawn counting, fake-hint wipe, fog pause ordering, event-bus leaks, HostMigration self-host-loss loop, lobby soft-lock); Android export pipeline; Nakama multiplayer architecture (lobby/room codes, host migration, reconnect, binary protocol, server-authoritative + AuthorityGuard); solo VS CPU mode. | Import 0 errs; smoke green; CI green |
| PR #22 (slice 3) | **R6 live strike-out search** — two search phases (zone+role swap), surviving-lines winner. | CI green |
| PR #23 (audit MAJORs) | MAJOR-1: line decay frozen to DRAWING only (lines now survive to scoring). MAJOR-2: EASY ghost lines placed during DRAWING (no more empty-zone search). Smoke upgraded to 2 passes. | CI green |
| PR #24 (slice 4) | **Defender argue + sneak complete** — CPU notice + penalty, argue stall, CPU counter-argue, sneak scoring, HUD banners; **+ lead fix:** CpuSearchController now listens for `EV_GAME_SNEAK_LINE_DRAWN` (without it, mid-phase sneaks could never be noticed — a real bug the smoke test caught and now covers); sneak pass de-duplicated; CI smoke timeout 90s → 240s. | Import 0 errs; smoke 3/3 (~65s); CI green |
| Sweep (main `70e452c`, `b377429`) | **Complete-codebase error sweep (owner: "test your code for any error and fix it")** — (1) event-bus subscription leaks fixed in GameWorld, LobbyScreen, MatchmakingScreen (`_exit_tree` offs added; all other subscribers audited symmetric); (2) human defender **ARGUE button** wired in real play (HUD, shown only during CPU search, honors use-cap, "ARGUED ✓" state); legacy ACCUSE button hidden from real matches + stale hint text fixed; static audit: no TODO/FIXME, no 4.4 API mistakes. | Import 0 errs; smoke 3/3; boot clean; CI green on main (both commits) |

## Appendix B — What Is Pending

| # | Item | Notes / why pending |
|---|---|---|
| 1 | **Owner hands-on playtest of the full VS CPU loop** | The machine validation is green; the owner's feel-check is the real gate (first KPI). |
| 2 | **Android export + physical device run** | Needs provisioning first: Godot 4.4 export templates + Android SDK + JDK17 + keystore (toolchain skill available). Verify install → splash → home on device. |
| 3 | **Home screen rework** | Visually appealing startup/home: village scene, real layout; make shop / settings / battle-pass / collection buttons functional (or decide their scope) — owner: after the basic game works. |
| 4 | **Tutorial sync to the tap-strike loop** | Tutorial still shows the old accuse path; decide update vs keep-as-is (see Appendix C item 4). |
| 5 | **Multiplayer device test** | Nakama online + WiFi Direct offline are architected and code-level fixed, but never run on real devices. |
| 6 | **Village art / visual integration** | Placeholder blocks in-world today; art exists in shared/artwork + spec docs; integration explicitly not gated on download size. |
| 7 | **Co-op PvE wave game (GDD long-form)** | Future target; needs owner go. |
| 8 | **Monetization validation** | No revenue yet; model undecided. |
| 9 | **Docs refresh** | README.md still describes the bootstrap demo (red/blue blocks); GDD stale numbers (Appendix C items 1–2); audit-findings.md would benefit from per-item status. |
| 10 | **Optional test hardening** | Smoke pass 3 drives `request_defender_argue()` via API; a "press the real ARGUE button" probe is a possible future strengthening. |

## Appendix C — Flagged Confusions / Uncleared Items

1. **GDD direction vs MVP direction.** `gdd.md` describes a co-op PvE wave game; the owner's 2026-09-08 rule made the VS CPU deception loop the MVP north star, with PvE as the long-form target. This is a *resolved* decision, but **gdd.md itself was never revised** to reflect it — anyone reading only the GDD gets the wrong "what we're building". Recommend a short GDD header note (authority pointer). *Needs: doc action, not a product decision.*

2. **GDD stale platform numbers vs owner performance target.** GDD says "APK ≤ 30 MB" and "stable 30 FPS on 2 GB devices". Owner retired the size cap (2026-08-23) and set "small download + fast startup + low memory + stable 60 FPS" with quality first. Superseded, but the GDD still shows the old numbers — same doc-freshness issue as (1). *Needs: doc action.*

3. **`cpu_argue_chance=0.5` — placeholder or final tuning value?** `project.godot` comment still says "(placeholder)", yet PR #24 implemented it as the *used* CPU counter-argue probability (50% — arguably high). Ambiguity: is 0.5 intentional or a number to revisit during playtest? *Needs owner/dev confirmation during the playtest pass.*

4. **Tutorial teaches the removed ACCUSE mechanic.** The real loop replaces accusation with tap-strike; the accusation path survives only as a "tutorial shim". Is the tutorial intentionally preserving the old mechanic (update needed), or should it be re-authored to teach tap-strike? *Needs owner decision.*

5. **Home-screen feature buttons (shop / battle-pass / collection).** They are non-functional chrome today. Are these placeholder (visual only) or planned features? Battle-pass/collection imply monetization and progression systems; their scope is unconfirmed. *Needs owner decision before or during the home-screen rework (Appendix B #3).*

6. **Multiplayer priority.** Online (Nakama) + WiFi Direct are built but never device-tested; the 2026-09-08 rule says MVP first. Is online play still the planned next step after the Android MVP, or does the PvE long-form target take precedence after the device run? *Needs owner re-confirmation of roadmap.*

7. *(Cleared, recorded for reference)* **Coin fairness vs difficulty**: coin is fair-random at every difficulty; difficulty affects search/sneak/hiding only. **Meeting happens once per round** (decides only the first searcher; the second search is a zone+role swap, no second coin). **Scoring** = surviving hidden lines per side (inverted-formula issue fixed in the audit campaign).