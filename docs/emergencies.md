# Emergency missions

Emergency missions are **pop-up guidance cards** that replace the active mission card
when a player's stat crosses a critical threshold, a hound wave begins, a chosen world
day arrives, the player becomes a ghost, or a living player stands beside a ghost
friend. They disappear when the condition has passed. They live in
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
  checks when the resolve condition is met. A hound, cycle, ghost or ghost_nearby
  emergency has no required row: its rows are optional guidance, because the card ends
  on world state, not on progress.
- **The chain is paused, not merely hidden.** Events during the emergency count toward
  the emergency's objectives, not the suspended chain objectives.
- **Auto-resolve.** The card ends by itself when the `resolve` condition becomes true;
  there is no button or objective that dismisses it.
- **Fire whenever they apply.** An emergency does not need a chain mission to replace:
  it can pop before mission 1, between missions, and after the chain is complete. When
  the chain is finished the overlay replaces the "All Missions Complete" card and Sync
  writes that card back after the recovered-card hold. The only suppressions are the 1 s
  startup initialisation and the two 3-second holds (a mission's completion card and an
  emergency's recovered card).
- **A death supersedes an active card.** While the player is a ghost only the death
  card is eligible: a stat or hound card is not actionable while dead, so it is dropped
  without a recovered card (and not marked as fired) and the death card activates. A
  ghost's stats are neutralised anyway (health is reset to the resurrect value, not 0),
  so stat triggers are never evaluated for one.
- **Stat events trigger immediately; the 1 Hz poll is the fallback** for silent changes
  (loading a save, console commands, a stat that never fires an event). A hound wave
  also pops immediately on the per-player `houndwarning` event (the first bark); the
  poll is the fallback when the player joins the warning late. A `cycle` trigger pops
  at dawn from the world-state `cycles` watcher, with the poll catching a mid-day join;
  a `kill` resolve ends the card the moment the world's `entity_death` event names the
  victim (with `or_gone`, the boss's `hasslerremoved` event ends it as well). The ghost
  trigger pops on the player's `ms_becameghost` event and resolves on
  `ms_respawnedfromghost`; `ghost_nearby` is proximity state and is polled.

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
| `trigger` | yes | Condition that starts the emergency. A `cycle` trigger may add `boss = "deerclops"` to suppress itself when that boss is disabled in this world. |
| `resolve` | yes | Condition that ends it. A `stat` trigger pairs with a `stat` resolve on the same stat; a `cycle` trigger pairs with a `kill` resolve; a `hounds` or `ghost_nearby` trigger pairs with the same kind's `clear` resolve; a `ghost` trigger pairs with a `revived` resolve. A `kill` resolve may add `or_gone = true` to also end when the boss leaves or despawns. |
| `frequency` | no | `"always"` overrides the global repeat mode for this entry. Used by momentary cards (death, a friend's ghost) that must return every time. The fired set is still persisted according to the global mode, so `"always"` is the only value accepted. |
| `objectives` | yes | A `kind = "stat"` emergency needs exactly one required `reach_stat` goal row matching `resolve`, plus any number of **optional** guidance rows. A `hounds`, `cycle`, `ghost` or `ghost_nearby` emergency has **only optional** rows. |

`title`, `subtext`, `resolved_subtext`, `hint`, and every `label` are **translation
keys**. Author them in English, keep them single-line, and stay within the card's width
budgets (title 27, subtext 52, label 28, hint 80 weighted columns; CJK counts 3).
Changing an English string orphans its translations until the locale files are updated.
After editing text, run `lua tools/gen_l10n.lua` and translate the new keys; see
[`localization.md`](localization.md).

## Conditions and thresholds

The manager never interprets conditions itself, so new kinds can be added in
`emergencies.lua` without touching it. Seven kinds exist today: `stat`, `hounds`,
`cycle` (a trigger), `kill` (a resolve), and the ghost set — `ghost` (a trigger),
`revived` (a resolve) and `ghost_nearby` (a trigger/resolve pair).

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

### `cycle` triggers

A cycle trigger is `{ kind = "cycle", day }`, where `day` is the 1-based world day the
HUD shows (day 1 is the engine's `cycles == 0`). It is true while that day is current:

```lua
trigger = { kind = "cycle", day = 30 }
```

The manager watches the world-state `cycles` variable, so the card pops at dawn when the
day starts; the 1 Hz poll catches a player who joins later that same day. Equality is
deliberate: a player who joins after the day has passed does not get a late card. `day`
must be a positive whole number — a missing or non-numeric day is false and never fires.
`cycle` is a trigger only; it pairs with a `kill` resolve.

A `cycle` trigger can name the boss it warns about:

```lua
trigger = { kind = "cycle", day = 30, boss = "deerclops" }
```

The whole trigger is then false unless that boss can appear in this world. For Deerclops
that means the world setting is not "Never" (`TUNING.SPAWN_DEERCLOPS`), the attack rate is
positive, and this shard has a `deerclopsspawner` component (the forest only). The card
therefore never appears in a world where there is nothing to warn about. The named boss
must match the resolve's `prefab`; the harness enforces it.

### `kill` resolves

A kill resolve is `{ kind = "kill", prefab }` and becomes true when an entity with that
prefab id dies **while the card is up**, whoever killed it:

```lua
resolve = { kind = "kill", prefab = "deerclops" }
```

The manager listens for the world's `entity_death` event, which `Health:SetVal` pushes
for every death — a player's hit, a tentacle, fire, drowning or starvation all count;
no attacker is required. The event is recorded on the showing's own state, so a death
that happened before the card appeared cannot resolve it.

By default a creature that merely wanders off or despawns is **not** a kill: the card
stays until the named creature actually dies. Bosses are the exception worth opting
into. `or_gone = true` also treats the boss's removal as an ending, so a Deerclops that
leaves when winter ends resolves the card instead of leaving it up forever:

```lua
resolve = { kind = "kill", prefab = "deerclops", or_gone = true }
```

That path uses the world's `hasslerremoved` event (pushed by the boss prefab when its
entity is removed after a kill, when it is stored on leaving at winter's end, or when it
is removed by an admin); the payload is the entity itself. It is only meaningful for
bosses that push that event. `kill` is a resolve only; a `cycle` trigger supplies the
start.

Both conditions are backed by facts recorded in `docs/dst-api.md` → *Entity death* and
*World day changes*.

### `ghost` and `revived`

A ghost trigger is `{ kind = "ghost" }`, true while the player carries the
`playerghost` tag. It is the only kind eligible while a player is a ghost, and it is a
trigger only: the way out is `{ kind = "revived" }`, true when the tag is gone. The
shipped `emergency_death` entry pairs them. Do **not** test health: `OnMakePlayerGhost`
resets a ghost's health to `TUNING.RESURRECT_HEALTH` (50), so `Health:IsDead()` is false
for one (`docs/dst-api.md` → *Player death, ghosts and revival*).

### `ghost_nearby` conditions

A living player standing beside a dead friend: `{ kind = "ghost_nearby", state = ... }`
with `"nearby"` (trigger) and `"clear"` (resolve), mirroring `hounds`. The scan looks
for `playerghost`-tagged players within 20 units to trigger and 25 to clear; the small
hysteresis keeps a drifting ghost from flapping the card. It is only evaluated while
the card's owner is alive (a ghost cannot help themself), and it is the last entry in
file order so the helper's own danger wins. The shipped `emergency_ghost_friend` entry
suggests the two ways to help: a Telltale Heart given to the ghost, or a Life Giving
Amulet dropped for it to haunt (a ghost cannot receive the amulet itself).

### Gated rows

Any **optional** row may be gated on a world setting with
`when = { setting = "portal_rez" }`; the manager drops it before writing the netvars, so
the client never draws it. The death card uses this for the Florid Postern row, which is
only actionable in Relaxed/Endless worlds (or any world with portal resurrection on).
See `docs/dst-api.md` → *Player death, ghosts and revival* for the setting.

When several entries match at once, the first one in file order wins.

## The goal row and optional guidance

Emergency objectives use exactly the same schema as chain objectives (see
[`objectives.md`](objectives.md)) and are tracked on the card like any other row.

- **Stat emergencies** have exactly one required row: a `reach_stat` objective whose
  `stat` and `threshold` match the emergency's `resolve` condition. It renders first,
  with a live percentage counter (`40/75%`), and shows a check once the resolve condition
  is met. The test harness enforces the match, so the card cannot promise a different
  threshold from the one that ends the emergency.
- **Hound, cycle, ghost and ghost_nearby emergencies** have no required row. Their rows
  are optional guidance (for example "Defend yourself", or the death card's list of
  ways back), because the card ends on world state rather than progress. The harness
  rejects a required row on a non-stat emergency.
- A gated optional row (`when`) is simply absent when the setting is off; it is never
  counted on the card and never affects completion.
- **Every other row is optional** (`optional = true`) and renders under the `Optional`
  heading as guidance.
- **The chain is never advanced by an emergency.** The manager refuses to complete an
  emergency through `CheckCompletion`; a stat emergency's required row and resolve
  condition are evaluated from the same live stat, and the emergency ends when
  `resolve` is true.

## Repeat frequency

The `EMERGENCY_FREQUENCY` mod option (Mods → Configure → **Emergency Repeat**) controls
how often each entry may fire for a player. An entry can override it with
`frequency = "always"`: the death card and the helper card do, because they are
momentary and "once per session" would silence the guidance on a second death. The
fired set is still saved according to the global mode, so `"always"` is the only
override the harness accepts.

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
and its progress; loading resumes the chain exactly where it was. The emergency itself is never restored.
For a finished chain there is no mission to suspend: the save already records
`completed`, so a load restores the "All Missions Complete" card, and any trigger that
still applies (still a ghost, still freezing) pops again after `Begin`. Whether the entry is re-armed
depends on when the save happened: an active card was never won, so at that point no id
has been recorded and the emergency can fire again after the load (`server` mode
included). A save during the 3-second recovered hold does record the id, because the
card had already resolved.

The fired set is also written to the save in `session` mode, so it can cross a shard
transfer; `OnLoad` then decides whether to keep it (see *Repeat frequency* above). In
`always` mode the set is never saved at all.

## Adding a condition kind

1. Add the kind to `Emergencies.VALID_KINDS` and handle it in `ConditionMet` in
   `emergencies.lua` (it currently reads stat fractions, hound-wave state, the world
   day, the per-showing kill set, the `playerghost` tag and nearby ghost players).
2. Export any new state/value set (like `VALID_HOUND_STATES` or
   `VALID_GHOST_STATES`) and validate it in `tests/manager_test.lua`, including the
   trigger/resolve restrictions (a kind may be trigger-only or resolve-only, as `cycle`
   and `kill`/`revived` are).
3. If the kind needs to be eligible while the player is a ghost, add it to
   `Emergencies.CanTriggerWhileGhost` (only `ghost` is today).
4. Document it here and add the engine facts to [`dst-api.md`](dst-api.md).

The manager needs no changes: it asks the module `IsTriggered` / `IsResolved`. An
event-driven kind can optionally add a listener in `manager.lua` that calls
`CheckEmergencies()` for an immediate pop; the 1 Hz poll remains the fallback. For a
condition that needs to remember something an event happened (like `kill`), extend the
per-showing state from `Emergencies.NewState()`, record it in `Emergencies.NoteEvent`,
and add the world listener that forwards to it — `kill` uses the world's `entity_death`
and `hasslerremoved` events. The state lives only from activation to resolve and is never
saved.
