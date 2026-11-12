# Emergency missions

Emergency missions are **pop-up guidance cards** that replace the active mission card
when a player's stat crosses a critical threshold, and disappear when the stat recovers.
They live in [`scripts/guidedmissions/emergencies.lua`](../scripts/guidedmissions/emergencies.lua),
separate from the ordered chain in `missions.lua`.

They are informational only. Showing or resolving an emergency never spawns items,
grants rewards, or changes a stat — it only swaps what the tracker displays.

## Behaviour

- **Pause & resume.** While an emergency is showing, the chain mission and its exact
  progress are suspended. When the emergency resolves, the chain card returns with the
  same counters and the same chain position. The chain does not advance.
- **The goal row shows the way out.** The card's one required row is a live
  `reach_stat` row ("Get back to 75% health") that mirrors the current percentage and
  checks when the resolve condition is met.
- **The chain is paused, not merely hidden.** Events during the emergency count toward
  the emergency's objectives, not the suspended chain objectives.
- **Auto-resolve.** The card ends by itself when the `resolve` condition becomes true;
  there is no button or objective that dismisses it.
- **No trigger while there is nothing to replace.** Emergencies are checked before the
  chain starts, after it is complete, during the 3-second completion hold, and while
  the recovered card holds. A dead/ghost player never triggers one.
- **Stat events trigger immediately; the 1 Hz poll is the fallback** for silent changes
  (loading a save, console commands, a stat that never fires an event).

## Entry schema

```lua
{
    id = "emergency_low_health",              -- unique, stable, lowercase
    title = "Bleeding Out",                   -- card heading
    subtext = "Patch yourself up...",         -- one flavour line
    resolved_subtext = "You're stable again.",-- optional; recovered card line
    hint = "Eat healing food...",             -- optional; "?" hover tooltip
    trigger = {
        kind = "stat",                        -- condition kind (extension point)
        stat = "health",                      -- "health" | "sanity"
        threshold = "<50",                    -- fires while the stat is below 50%
    },
    resolve = {
        kind = "stat",
        stat = "health",
        threshold = ">=75",                   -- ends once the stat is 75% or more
    },
    objectives = {
        -- Exactly one required row: the recovery goal, matching `resolve`.
        { type = "reach_stat", stat = "health", threshold = ">=75",
          label = "Get back to 75% health" },
        -- Every other row is optional guidance.
        { type = "heal", count = 20, label = "Restore 20 health", optional = true },
        { type = "craft", prefab = "healingsalve", count = 1,
          label = "Craft a Healing Salve", optional = true },
    },
},
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Unique, stable, lowercase `[a-z0-9_]`. Used by the repeat tracker and the server log, never saved as a mission id. |
| `title` | yes | Card heading; the `emergency` state colours it red. |
| `subtext` | yes | One flavour line, about 45 characters. |
| `resolved_subtext` | no | Replaces `subtext` on the 3-second recovered card. Defaults to `subtext`. |
| `hint` | no | Same hover tooltip as a chain mission. Hidden on the recovered card. |
| `trigger` | yes | Condition that starts the emergency. |
| `resolve` | yes | Condition that ends it. Must use the same `stat` as `trigger`. |
| `objectives` | yes | Exactly one required `reach_stat` goal row matching `resolve`, plus any number of **optional** guidance rows. |

## Conditions and thresholds

A condition is `{ kind, stat, threshold }`. `kind = "stat"` is the only kind today;
`stat` is `"health"` or `"sanity"`. The manager never interprets conditions itself, so
new kinds can be added in `emergencies.lua` without touching it.

`threshold` is a **string** so the comparison is explicit, and the value is a percentage
of the stat's maximum (0-100):

| Threshold | True when |
|---|---|
| `"<50"` | below 50% |
| `"<=50"` | 50% or below |
| `">50"` | above 50% |
| `">=75"` | 75% or above |

Whitespace around the operator/number is allowed; decimals are allowed. A malformed
threshold, a missing stat component, or an unknown kind is simply `false` — it never
errors and never triggers. For emergencies, `trigger` must use `<`/`<=` and `resolve`
must use `>`/`>=`, and the resolve value must be at or above the trigger value. The gap
is the hysteresis: the stat has to recover past the resolve line before the same
emergency can fire again.

Health is read as `currenthealth / maxhealth`; sanity as `current / max`. Sanity's
`GetPercent()` is deliberately not used because induced insanity/lunacy forces it to
0 or 1, which would hide a real drop.

When several entries match at once, the first one in file order wins.

## The goal row and optional guidance

Emergency objectives use exactly the same schema as chain objectives (see
[`objectives.md`](objectives.md)) and are tracked on the card like any other row.

- **Exactly one required row** must be a `reach_stat` objective whose `stat` and
  `threshold` match the emergency's `resolve` condition. It renders first, with a live
  percentage counter (`40/75%`), and shows a check once the resolve condition is met.
  The test harness enforces the match, so the card cannot promise a different threshold
  from the one that ends the emergency.
- **Every other row is optional** (`optional = true`) and renders under the `Optional`
  heading as guidance.
- **Completion is still stat-driven.** The manager refuses to complete an emergency
  through `CheckCompletion`; the required row and the resolve condition are evaluated
  from the same live stat, and the emergency ends when `resolve` is true.

## Repeat frequency

The `EMERGENCY_FREQUENCY` mod option (Mods → Configure → **Emergency Repeat**) controls
how often each entry may fire for a player:

| Mode | Fires | Survives a relog / world load | Re-armed by |
|---|---|---|---|
| `always` (Every time) | every time the trigger condition becomes true again after a resolve | — | the resolve condition |
| `session` (Once per session, default) | once per player per session | no | rejoining / restarting the world |
| `server` (Once per server) | once per player per world | yes (saved with the player) | regenerating the world, or `c_resetmissions()` |

The tracking is always **per player**, because every player progresses independently;
"once per server" is not a group-wide one-shot. The option is server-side and read when
the mod loads, so changing it needs a restart or a mod disable/enable.

`c_setmission(...)` keeps the fired set; `c_resetmissions()` clears it so an admin can
test an emergency again.

## Saving

Only the chain is saved. If a player saves while an emergency is showing (or while the
recovered card holds), the save stores the suspended chain mission and its progress;
loading resumes the chain exactly where it was. The emergency itself is never restored,
so a `session`-mode trigger is re-armed by the load, and a `server`-mode trigger is
suppressed because its id was saved with the player.

## Adding a condition kind

1. Add the kind to `Emergencies.VALID_KINDS` and handle it in `ConditionMet` in
   `emergencies.lua` (it currently reads stat fractions).
2. Add any new `stat`/identifier to the validation in `tests/manager_test.lua`.
3. Document it here.

The manager needs no changes: it asks the module `IsTriggered` / `IsResolved`.
