# Plan — Multiplayer mode: shared structures satisfy `build` objectives

> **Status: not implemented.** This is a design + implementation plan, not a
> description of current behaviour. `docs/objectives.md` remains the reference for what
> the mod does today.

## Context

In DST one Science Machine, Alchemy Engine, Fire Pit, or Birdcage serves the whole
base — nobody needs their own. The mission chain currently asks **every** player to
build one, because `build` objectives only listen for the `buildstructure` event on
the acting player. Four missions are affected:

| Mission | Shared row | Other required rows (unchanged) |
|---|---|---|
| `science_machine` | `researchlab` | `prototype` ×2 |
| `build_camp` | `firepit` | build `treasurechest` |
| `level_up` | `researchlab2` | `prototype` ×1 |
| `birdcage` | `birdcage` | craft `birdtrap` |

Goal: a **Multiplayer Mode** mod option that lets a player's `build` row auto-check
when an equivalent structure already stands close by, so players sharing a base don't
each build one. Player-specific rows (prototypes, chest, bird trap) still have to be
done, and the mission finishes with the normal completion card and chat announce.

Decisions from the user: trigger is **proximity** ("structure exists 1–2 screens
away"), scope is the **shared objective only**, feedback is the **normal completion
card**.

This deliberately introduces **no shared or cross-player state**: no `AllPlayers`
scan, no completed-mission registry, no world save. It only reads world entities, so
the per-player progression invariant and the information-only invariant both hold.

## Design

- New mod option `MULTIPLAYER_MODE` (boolean, default **Disabled**), surfaced as
  `Settings.multiplayer_mode`.
- New objective field `shared = true`, valid **only on `build`** objectives. It marks
  "another copy of this structure satisfies me".
- `Objectives.LiveProgress` gains a branch: for a `shared` build objective, count
  matching entities within `SHARED_STRUCTURE_RADIUS` of the player and return that
  count (capped at `count`); return `nil` — not `0` — when nothing is near, so
  progress is **sticky** and walking away never unchecks a completed row.
- The manager already calls `LiveProgress` from `RefreshLiveObjectives` (once per
  second via the existing poll, `manager.lua:430-451`) and from `InitialProgress`
  (mission start, `objectives.lua:245-257`). So the row checks immediately on mission
  start if a structure is nearby, and live when someone builds one mid-mission. No
  manager change is required for the core behaviour.
- No netvar or HUD change: the row simply renders as checked through the existing
  `rows` contract.

### Engine facts (verified against the installed game scripts)

- `TheSim:FindEntities(x, y, z, radius, musttags, excludetags)` — usage confirmed at
  `scripts/components/combat.lua:1703`.
- Filter with `musttags = { "structure" }`. `firepit` (`scripts/prefabs/firepit.lua:161`)
  and `birdcage` (`scripts/prefabs/birdcage.lua:585`) add it explicitly;
  `researchlab`/`researchlab2` are produced by the factory in
  `scripts/prefabs/scienceprototyper.lua`, which adds `structure` at ~line 193
  **before** `SetPristine()`, so the tag exists server-side.
- `TILE_SCALE = 4` (`scripts/constants.lua:17`). One screen is roughly 8–10 tiles
  across, so "1–2 screens" ≈ 32–80 units. Use a module constant
  `SHARED_STRUCTURE_RADIUS = 60` (15 tiles) with that rationale in a comment.

Match by `ent.prefab == objective.prefab`, and skip the scan entirely when
`Settings.multiplayer_mode` is off or the objective is not `shared`.

## Changes

### Production

1. **`modinfo.lua`** — add a `MULTIPLAYER_MODE` entry after `ANNOUNCE_MISSIONS`,
   following the existing boolean shape (`Enabled`/`Disabled`, `default = false`).
   Label "Multiplayer Mode"; hover: auto-complete a build objective when the structure
   already stands nearby, so players sharing a base don't each build one.

2. **`scripts/guidedmissions/settings.lua`** — add `multiplayer_mode = false` with a
   one-line comment, matching the existing style.

3. **`modmain.lua`** (near lines 18–29) — `Settings.multiplayer_mode =
   GetModConfigData("MULTIPLAYER_MODE") == true`. Strict `== true` keeps the default
   off and needs no `tonumber` (the mod env has none).

4. **`scripts/guidedmissions/objectives.lua`**
   - `require("guidedmissions/settings")` alongside the existing requires.
   - Add `SHARED_STRUCTURE_RADIUS` and a local `CountNearbyStructures(inst, prefab)`
     that reads `inst.Transform:GetWorldPosition()` and calls
     `GLOBAL.TheSim:FindEntities(...)`, guarding for nil `TheSim`/`Transform`.
   - Add `Objectives.IsShared(objective)` (mirrors `IsOptional`).
   - Extend `Objectives.LiveProgress` (lines 234-243) with the `shared` build branch
     described above, and update its comment to say which row kinds it serves.

5. **`scripts/guidedmissions/missions.lua`** — add `shared = true` to exactly four
   objectives: `researchlab` (`science_machine`), `firepit` (`build_camp`),
   `researchlab2` (`level_up`), `birdcage` (`birdcage`). Leave `treasurechest` and
   `birdtrap` unshared. Add one line to the header comment block documenting the new
   field.

### Tests

6. **`tests/manager_test.lua`**
   - Stub `TheSim = { entities = {}, FindEntities = function(_, x, y, z, radius, musttags) ... end }`
     near the `TheWorld` stub (line 98), filtering the configured entities by
     `musttags` and radius so the tag filter is exercised.
   - Give `NewInst` (line 157) an `inst.Transform = { GetWorldPosition = ... }`.
   - Extend `ValidateObjectiveFields` (line 316) to check `shared` is boolean and is
     set only on `build` objectives.
   - New fixtures using the existing `Spawn`/`Activate` helpers:
     - mode off + structure present → shared row stays `0`;
     - mode on + nothing nearby → stays `0`;
     - mode on + structure present at mission start → `InitialProgress` yields `1`
       and the row renders done;
     - mode on + structure appears later → `Advance(1)` (poll) ticks the row and
       completes the mission with the usual `won` card / announce;
     - mode on + structure leaves range → row stays checked.
   - Restore `Settings.multiplayer_mode` and `TheSim.entities` after each block, as
     the emergency tests already do for `Settings.emergency_frequency`.

7. **`tests/modmain_test.lua`** — add `MULTIPLAYER_MODE = true` to `config_values`
   (line 77) and assert `Settings.multiplayer_mode == true` beside the existing
   `emergency_frequency` assertion (line 159).

### Docs

8. **`docs/objectives.md`** — document `shared` in the `build` section (field table +
   a short "Multiplayer mode" paragraph: only `build`, only when the option is on,
   proximity radius, sticky once checked) and note it in the objective-fields
   discussion.
9. **`README.md`** — mention the option in the Configure line (~13-14); add a "How it
   plays" bullet; add a `shared` note under the objective table; amend the Known
   limitations line "Progress is per player; there is no shared or team mission state"
   to explain that MP mode only auto-satisfies nearby build rows; reword the Roadmap
   "shared progress" entry so it reflects this partial delivery.
10. **`docs/dst-api.md`** — record the verified `TheSim:FindEntities` signature, the
    `structure` tag on all four prefabs (with the scienceprototyper factory note), and
    `TILE_SCALE = 4`, per the repo's "update it as you go" rule.

## Verification

1. `cmd //c ".\\verify.cmd"` from the repo root — syntax + manager harness + modmain
   harness. All new fixtures must pass.
2. `sh tests/preview/run.sh` — no HUD change is expected, but this confirms the
   tracker still renders the existing card states.
3. **Human step (in-game):** enable the mod, set **Multiplayer Mode → Enabled** in
   Mods → Configure, start/rejoin a world and run `c_setmission("science_machine")`.
   - Stand next to an existing Science Machine → the "Build a Science Machine" row
     checks; prototype twice and the mission completes with the normal card.
   - Stand far from any machine → the row stays unchecked.
   - With Multiplayer Mode disabled, the row ignores nearby machines.
   Send back the newest `master_server_log.txt` (or point at it) to confirm no errors.
