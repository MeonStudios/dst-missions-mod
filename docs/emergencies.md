# Emergency missions

Emergency missions are **pop-up guidance cards** that replace the active mission card
when a player's stat crosses a critical threshold or a hound wave begins, and disappear
when the danger has passed. They live in
[`scripts/guidedmissions/emergencies.lua`](../scripts/guidedmissions/emergencies.lua),
separate from the ordered chain in `missions.lua`.

They are informational only. Showing or resolving an emergency never spawns items,
grants rewards, or changes a stat — it only swaps what the tracker displays.

## Behaviour

- **Pause & resume.** While an emergency is showing, the chain mission and its exact
  progress are suspended. When the emergency resolves, the chain card returns with the
  same counters and the same chain position. The chain does not advance.
- **The goal row shows the way out.** A stat emergency's one required row is a live
  `reach_stat` row ("Get back to 75% health") that mirrors the current percentage and
  checks when the resolve condition is met. A hound emergency has no required row: its
  rows are optional guidance, because the wave ends on world state, not on progress.
- **The chain is paused, not merely hidden.** Events during the emergency count toward
  the emergency's objectives, not the suspended chain objectives.
- **Auto-resolve.** The card ends by itself when the `resolve` condition becomes true;
  there is no button or objective that dismisses it.
- **No trigger while there is nothing to replace.** Emergencies are checked before the
  chain starts, after it is complete, during the 3-second completion hold, and while
  the recovered card holds. A dead/ghost player never triggers one.
- **Stat events trigger immediately; the 1 Hz poll is the fallback** for silent changes
  (loading a save, console commands, a stat that never fires an event). A hound wave
  also pops immediately on the per-player `houndwarning` event (the first bark); the
  poll is the fallback when the player joins the warning late.

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
        stat = "health",                      -- health/sanity/hunger/wetness/temperature
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
| `resolve` | yes | Condition that ends it. Must use the same `kind` as `trigger`; for `kind = "stat"` it must also use the same `stat`. |
| `objectives` | yes | A `kind = "stat"` emergency needs exactly one required `reach_stat` goal row matching `resolve`, plus any number of **optional** guidance rows. A `kind = "hounds"` emergency has **only optional** rows. |

`title`, `subtext`, `resolved_subtext`, `hint`, and every `label` are **translation
keys**. Author them in English, keep them single-line, and stay within the card's width
budgets (title 27, subtext 52, label 28, hint 80 weighted columns; CJK counts 3).
Changing an English string orphans its translations until the locale files are updated.
After editing text, run `lua tools/gen_l10n.lua` and translate the new keys; see
[`localization.md`](localization.md).

## Conditions and thresholds

The manager never interprets conditions itself, so new kinds can be added in
`emergencies.lua` without touching it. Two kinds exist today.

### `stat` conditions

A stat condition is `{ kind = "stat", stat, threshold }`; `stat` is `"health"`,
`"sanity"`, `"hunger"`, `"wetness"` or `"temperature"`.

`threshold` is a **string** so the comparison is explicit. Health, sanity, hunger and
wetness use a percentage of the stat's maximum (0-100):

| Threshold | True when |
|---|---|
| `"<50"` | below 50% |
| `"<=50"` | 50% or below |
| `">50"` | above 50% |
| `">=75"` | 75% or above |

**Temperature is the exception:** it is a raw degrees reading, so its thresholds are in
degrees and may be negative — `"<0"` is freezing, `">70"` is overheating (DST's default
overheat line). Whitespace around the operator/number is allowed; decimals are allowed.
A malformed threshold, an out-of-range value, a missing stat component, or an unknown
kind is simply `false` — it never errors and never triggers.

`trigger` and `resolve` must use **opposite** comparisons, with the resolve line on the
safe side of the trigger, so the stat has to recover past it before the same emergency
can fire again:

- health, sanity, hunger and freezing go low → high (`trigger "<50"`, `resolve ">=75"`);
- wetness and overheating go high → low (`trigger ">50"`, `resolve "<=20"`).

Health is read as `currenthealth / maxhealth`; sanity, hunger and wetness as
`current / max` (wetness comes from the `moisture` component's
`moisture / maxmoisture`); temperature as `temperature.current` in degrees. Sanity's
`GetPercent()` is deliberately not used because induced insanity/lunacy forces it to
0 or 1, which would hide a real drop.

Hunger pushes `hungerdelta` from its 1 Hz decay task, and temperature crossing events
(`startfreezing`, `startoverheating`, and their `stop` counterparts) are listened for,
so those emergencies react immediately; the poll is the fallback for loads and console
changes. The moisture and temperature components push `*delta` every frame, so those
streams are **not** forwarded; wetness and custom temperature thresholds are evaluated
by the 1 Hz poll (at most one second late).

### `hounds` conditions

A hound-wave condition is `{ kind = "hounds", state }`, where `state` is one of:

| State | True when |
|---|---|
| `"warning"` | the shard's `hounded` component is in its pre-attack warning — the bark `ANNOUNCE_HOUNDS` answers |
| `"attacking"` | the wave is spawning hounds |
| `"nearby"` | at least one living, non-pet hound stands within 60 units of the player |
| `"clear"` | not warning, not spawning, and no living wave hound nearby |

The shipped `emergency_hound_wave` entry triggers on `"warning"` (the first bark, with
the 1 Hz poll as the fallback for a late join) and resolves on `"clear"`. `trigger` must
not use `"clear"`, which would fire when nothing is happening. The state reads
`TheWorld.components.hounded` and a `TheSim:FindEntities` scan; `pet_hound` (MacTusk's
hounds) is excluded, and hounds are matched by the vanilla `hound` tag, so ice/fire
variants and the `warglet` upgrade count. See [`dst-api.md`](dst-api.md), "Hound waves".

The warning flag is **shard-wide**, while vanilla targets only land players. A player on
a boat therefore also sees the card even though the wave will not spawn hounds for them;
the card clears on the normal resolve condition. This is a deliberate simplification
that avoids duplicating vanilla's arena/water location checks.

To test it in game without waiting for a natural wave, run this in the server console:

```lua
TheWorld:PushEvent("hounded_forceplannewattack", { multtimetoattack = 0.01 })
```

The intro warning lasts 120 s, so scaling the 5-8 day delay down to well under 120 s
puts the shard straight into the warning on the next tick. Do **not** use
`hounded:ForceNextWave()` for this: it sets the attack time to 0 and skips the warning,
so no card appears.

When several entries match at once, the first one in file order wins.

## The goal row and optional guidance

Emergency objectives use exactly the same schema as chain objectives (see
[`objectives.md`](objectives.md)) and are tracked on the card like any other row.

- **Stat emergencies** have exactly one required row: a `reach_stat` objective whose
  `stat` and `threshold` match the emergency's `resolve` condition. It renders first,
  with a live percentage counter (`40/75%`), and shows a check once the resolve condition
  is met. The test harness enforces the match, so the card cannot promise a different
  threshold from the one that ends the emergency.
- **Hound emergencies** have no required row. Their rows are optional guidance (for
  example "Defend yourself" or "Equip a spear"), because the card ends on world state
  rather than progress. The harness rejects a required row on a non-stat emergency.
- **Every other row is optional** (`optional = true`) and renders under the `Optional`
  heading as guidance.
- **The chain is never advanced by an emergency.** The manager refuses to complete an
  emergency through `CheckCompletion`; a stat emergency's required row and resolve
  condition are evaluated from the same live stat, and the emergency ends when
  `resolve` is true.

## Repeat frequency

The `EMERGENCY_FREQUENCY` mod option (Mods → Configure → **Emergency Repeat**) controls
how often each entry may fire for a player:

| Mode | Fires | Survives | Re-armed by |
|---|---|---|---|
| `always` (Every time) | every time the trigger condition becomes true again after a resolve | nothing | the resolve condition |
| `session` (Once per session, default) | once per player per session | a caves / shard trip (the set rides in the player save across the transfer) | rejoining / restarting the world |
| `server` (Once per server) | once per player per world | any relog or world load (saved with the player) | regenerating the world, or `c_resetmissions()` |

A shard transfer is not a new session: moving to the caves and back keeps the fired
set. Only a fresh join or a world load re-arms `session` mode. (`server` mode keeps the
set across those too.)

The player save carries `inst.migration` even for loads that are not a live transfer —
an entity that loaded but never spawned (a client rejected at the mod handshake, a
world shut down mid-transfer) keeps the engine's migration record on disk. So `OnLoad`
does not trust that flag alone: the save also stores the writing shard's
`TheWorld.meta.session_identifier`, and the fired set is kept only when it matches the
`sessionid` in the migration record and the record names a different shard. A stale
record therefore still starts a new session. See `dst-api.md` → *Shard migration*.

The tracking is always **per player**, because every player progresses independently;
"once per server" is not a group-wide one-shot. The option is server-side and read when
the mod loads, so changing it needs a restart or a mod disable/enable.

An entry is remembered only once it has been **seen through**: the recovered ("won")
card is what marks it as fired. A card that is interrupted before it resolves — an
admin jump, a save/load, the player leaving — is not remembered, so the same emergency
can fire again. `always` remembers nothing at all.

`c_setmission(...)` keeps the fired set; `c_resetmissions()` clears it so an admin can
test an emergency again.

## Saving

The chain and (in `session`/`server` mode) the emergency fired set are saved. If a
player saves while an emergency is showing, the save stores the suspended chain mission
and its progress; loading resumes the chain exactly where it was. The emergency itself is never restored. Whether the entry is re-armed
depends on when the save happened: an active card was never won, so at that point no id
has been recorded and the emergency can fire again after the load (`server` mode
included). A save during the 3-second recovered hold does record the id, because the
card had already resolved.

The fired set is also written to the save in `session` mode, so it can cross a shard
transfer; `OnLoad` then decides whether to keep it (see *Repeat frequency* above). In
`always` mode the set is never saved at all.

## Adding a condition kind

1. Add the kind to `Emergencies.VALID_KINDS` and handle it in `ConditionMet` in
   `emergencies.lua` (it currently reads stat fractions and hound-wave state).
2. Export any new state/value set (like `VALID_HOUND_STATES`) and validate it in
   `tests/manager_test.lua`, including the trigger/resolve restrictions.
3. Document it here and add the engine facts to [`dst-api.md`](dst-api.md).

The manager needs no changes: it asks the module `IsTriggered` / `IsResolved`. An
event-driven kind can optionally add a listener in `manager.lua` that calls
`CheckEmergencies()` for an immediate pop; the 1 Hz poll remains the fallback.
