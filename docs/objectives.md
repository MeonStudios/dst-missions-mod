# Objective reference

Every objective in [`scripts/guidedmissions/missions.lua`](../scripts/guidedmissions/missions.lua)
is a small table with a `type` and a few type-specific fields. This file is the
authoritative list of those types and options.

**Keep this file in sync.** When an objective type is added, removed, or its fields,
labels, icons, or matching rules change, update this file in the same change — and the
summary table in the [`README`](../README.md). The checklists at the bottom list every
place that needs touching.

## Mission shape

```lua
{
    id = "first_night",                               -- unique, stable, lowercase
    title = "Let There Be Light",                     -- card heading
    subtext = "The dark is not your friend. Probably.", -- one flavour line, ~45 chars
    hint = "A torch goes in your hand, a campfire on the ground.", -- optional
    objectives = {
        { type = "craft", prefab = "torch", count = 1, label = "Craft a torch" },
        { type = "build", prefab = "campfire", count = 1, label = "Build a campfire" },
        { type = "survive", day = 2, label = "Survive the first night" },
        { type = "pick", prefab = "flower", count = 1, label = "Pick a flower",
          optional = true },                              -- does not block completion
    },
}
```

| Mission field | Required | Notes |
|---|---|---|
| `id` | yes | Unique, stable, lowercase `[a-z0-9_]`. Saved progress is keyed by id, not by position, so reordering missions is safe but renaming an id resets that mission's players. |
| `title` | yes | Shown as the card heading. |
| `subtext` | yes | One flavour line under the objectives. Keep it to about 45 characters; the card has a single line. |
| `hint` | no | A sentence or two of help, shown in a hover tooltip behind a "?" button in the card's title band. The HUD wraps it to 240 px and caps it at 4 lines (with an ellipsis), so keep it short. Omit it and no button appears. The hint is not shown on the 3-second completion card. |
| `objectives` | yes | At least one required objective (see below). The mission completes when **all required** rows complete. |

Any objective may set `optional = true`. Optional objectives are tracked and counted
exactly like required ones, but they never gate completion: a mission finishes as soon
as its required objectives are done, and optional rows that are still unfinished stay
unchecked on the completion card (the 3-second hold only forces the required rows to
"done"). The tracker always renders required rows first and groups optional rows below
them under a small gold `Optional` heading, with the optional labels and counters
dimmed; authored order is kept within each group. Every mission must have at least one
required objective; a mission of only optional objectives would complete the moment it
starts.

A `tip` row is always optional and never completes at all — see [`tip`](#tip) below.

Missions run in file order. Each player advances independently after a 3-second
"won" hold. The last mission is followed by a terminal "All Missions Complete" card.

### Character overrides

Some characters cannot perform a goal at all: Wigfrid only swallows meat and
goodies, Warly only eats Crock Pot food, Wickerbottom cannot sleep. A row can
name a replacement goal per character prefab:

```lua
{ type = "eat", prefab = "butterflywings", count = 1, label = "Eat a butterfly wing",
  overrides = {
      wathgrithr = { type = "craft", prefab = "healingsalve", count = 1,
                     label = "Craft a Healing Salve" },
      warly = { type = "craft", prefab = "healingsalve", count = 1,
                label = "Craft a Healing Salve" },
  } },
```

- **Keys are character prefab ids** (`wathgrithr`, `warly`, `wurt`,
  `wickerbottom`, `wormwood`, ...), read from the player. A character without an
  entry sees the base row unchanged; the override is resolved once when the
  mission (or emergency) starts.
- **The value is a complete objective** — its own `type`, fields and `label`
  (another translation key) — validated by the same rules as a base row.
- **`false` hides the row for that character.** No tracker row and no progress
  slot are created, so the card is simply shorter; the hidden label is never
  sent and needs no translation. Use it for advice that would only ever apply
  to other characters, such as a sleep row on Wickerbottom's card:

  ```lua
  { type = "sleep", count = 1, label = "Sleep in a tent", optional = true,
    overrides = { wickerbottom = false } }
  ```

  Hiding a **required** row is allowed only if at least one other required row
  remains for that character (the harness enforces it): a mission with no
  required rows completes the moment it starts. After a data update that adds
  or removes hidden rows, that character's remaining rows shift index, which
  can misalign in-progress saved progress for that character only.
- **A replacement changes only the goal.** The row keeps its position, its
  progress index and its `optional` flag, so an override cannot turn a required
  row optional for one character. (Hiding a row is the exception: it removes the
  row and its slot.) Do not set `optional` inside an override, and do not nest
  another `overrides` table.
- **A `tip` override** (guidance that never completes) is allowed only on a row
  that is already optional; a tip can never satisfy a required gate.
- Missions and emergency entries both support overrides. The mission `hint` is
  shared by every character (it is not overridable), so word it to cover both
  routes.
- Character abilities are engine facts, not data the mod reads: entries are
  maintained by hand. The current restrictions are recorded in
  [`dst-api.md`](dst-api.md), "Character restrictions".

### Text and translation

`title`, `subtext`, `hint`, and every objective `label` are **translation keys**: the
server sends the English source and each client renders it in its own language. Author
them in English, keep them single-line, and never use `|`, `;`, quotes, or newlines
(the row wire format and the locale-file scan depend on it).

Translations must fit the card's fixed layout. The l10n harness enforces these
per-field budgets in weighted columns (CJK glyphs count 3): **title 27, subtext 52,
label 28, hint 80**. Reword a translation that does not fit rather than growing the
card. See [`localization.md`](localization.md) for the workflow.

Editing an English string changes its key and orphans the existing translations. After
any text edit, regenerate the manifest and translate the new keys in every shipped
locale:

```bash
lua tools/gen_l10n.lua
lua tests/l10n_test.lua
```

The runtime always falls back to English when a key or locale is missing, so a
half-updated translation degrades gracefully instead of crashing.

## Emergency missions

Pop-up emergencies are a separate, unordered collection in
[`emergencies.lua`](../scripts/guidedmissions/emergencies.lua). They reuse the objective
schema on this page, but each entry has `trigger`/`resolve` conditions instead of a chain
position. A **stat** emergency has exactly one required `reach_stat` goal row matching
its resolve threshold, plus any number of optional rows; a **hound-wave** emergency has
only optional rows. Either way the card resolves on its condition, never on objective
completion. See [`emergencies.md`](emergencies.md) for the full schema.

## How progress is counted

There are three mechanisms:

- **Inventory-derived (reread on inventory events):** `collect`, `collect_food`,
  and `craft`. Any player `itemget`, `gotnewitem`, `newactiveitem`, or
  `setoverflow` schedules one reread on the next tick and a burst of pickups
  coalesces into that one read. Progress is the **peak holding** seen since the
  mission started — spending or dropping items never removes credit, but picking
  items up later can raise it. The inventory at the moment the mission starts
  counts as the starting value. `craft` is a special case: it also credits the
  `builditem` craft event, and the inventory read is what lets an item crafted
  before the mission started (or handed over by a teammate) satisfy the row.
- **Live state (polled every second):** `survive` reads the world day, `equip`
  mirrors the current equipment slots, and `reach_stat` mirrors its stat.
  Equip rows also refresh immediately on `equip`/`unequip`, and
  health/sanity/hunger rows on their `*delta` events; wetness and temperature
  rely on the poll because those components emit every frame. The survive read
  only syncs when the world day changes.
- **Event-driven:** everything else. Each event adds an increment (usually 1, but
  `heal`/`sanity` add points).

Rows render as `label`, icon, `progress/count`, and a green check when done. Optional
rows sit in their own group below an `Optional` heading and use a dimmer colour. During
the completion hold the required rows are shown checked; optional rows show their real
state, so an unfinished optional objective is visibly left unchecked. A `tip` row is
not counted at all: its counter stays at `0/1` and it never checks.

## Icons

The server writes an icon id per row; the HUD resolves it as:

1. `brain` → the HUD sanity-badge art (`images/global_redux.xml`).
2. `heart` → the HUD health-badge art (`images/global_redux.xml`).
3. `hunger` → the HUD hunger-badge art (`images/global_redux.xml`).
4. `flower` → the world flower animation (flowers have no inventory icon).
5. `evergreen_normal` → the world tree animation (trees have no inventory icon).
6. Any other id `<id>` → `images/inventoryimages*.xml` lookup for `<id>.tex`.

Any other id with no matching art draws nothing (the row is text-only), which is a
safe fallback for modded prefabs. See `docs/dst-api.md`, "HUD icon art", for how the
atlases were verified.

## Objective types

Every objective needs a `type` and a `label`. Each table below lists exactly the fields
that type reads — nothing it ignores. Required fields have no default (`—`); optional
fields show theirs. `label` is required on every type and is not repeated in the tables:
it is the row text, authored per objective, and never carries a count (the tracker
renders the counter separately). Ids (`prefab`, `icon`, recipe ids) are lowercase
`[a-z0-9_]`.

The examples use every field the type supports.

### `collect`

Acquire items and hold them.

| Field | Required | Default |
|---|---|---|
| `prefab` | yes | — |
| `count` | yes | — |

- **Completes when:** the player has held `count` of `prefab` at some point (peak
  holdings, stack sizes counted).
- **Matching:** an inventory scan on the tick after an inventory event; the event
  payload is ignored. Items already carried when the mission starts count.
- **Icon:** `prefab`.
- **Not for:** food in general (use `collect_food`) or raw-food-specific goals; it
  compares exact prefab ids.

```lua
{ type = "collect", prefab = "flint", count = 3, label = "Collect flint" }
```

### `craft`

Craft or already have `count` inventory items.

| Field | Required | Default |
|---|---|---|
| `prefab` | yes | — |
| `count` | yes | — |

- **Completes when:** the player crafts an item whose recipe or product id is
  `prefab`, or already carries `count` of it. An item crafted before the mission
  started, found, or handed over by a teammate counts too — the player is never
  asked to craft a duplicate of something already in the inventory.
- **Trigger:** the `builditem` player event, fired for products that go into the
  inventory (torch, spear, axes, armour), plus the inventory reread described
  under [How progress is counted](#how-progress-is-counted). Progress is the
  higher of crafts observed and the **peak** inventory count, so dropping the
  item does not remove credit.
- **Icon:** `prefab`.
- **Not for:** structures placed in the world — those fire `buildstructure` only.
  Use `build` for firepits, Science Machines, walls, chests, and so on. The wrong
  type never completes.

```lua
{ type = "craft", prefab = "axe", count = 1, label = "Craft an axe" }
```

### `build`

Place `count` structures in the world.

| Field | Required | Default |
|---|---|---|
| `prefab` | yes | — |
| `count` | yes | — |
| `shared` | no | off |

- **Completes when:** the player places the structure `prefab`, `count` times.
- **Trigger:** the `buildstructure` player event, plus a 1-second poll for
  `shared` rows (see below).
- **Icon:** `prefab`.
- **Not for:** carryable products — those are `craft`.

```lua
{ type = "build", prefab = "firepit", count = 1, label = "Build a Fire Pit" }
```

**Multiplayer mode.** `shared = true` is valid on `build` rows only. When the
**Multiplayer Mode** mod option is enabled (Mods → Configure), the row also
counts a copy of the structure already standing within about 15 tiles (60 world
units, roughly two screens) of the player — one base fire pit or Science
Machine serves everyone. The row checks immediately at mission start if the
structure is already there, and mid-mission when a teammate builds one; once
checked it stays checked as the player walks away. With the option off, `shared`
does nothing and the player must build their own, which is the normal rule.
This reads world entities only: it creates no shared or team mission state.

```lua
{ type = "build", prefab = "researchlab", count = 1, label = "Build a Science Machine",
  shared = true }
```

### `deploy`

Deploy `count` deployable items on the ground.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any deployable item |
| `icon` | no | `prefab`, otherwise none |

- **Completes when:** the player successfully deploys an item, `count` times.
  Deploying is the right-click/click-on-the-world action for items that are put
  down and consume or convert themselves: the Garden Digamajig, bird traps,
  boat kits, turf.
- **Trigger:** the `deployitem` player event, pushed by `Deployable:Deploy` with
  the item's prefab (`components/deployable.lua:142`). Credit lands on the
  action, not on any delayed effect — the digamajig drills for a moment and
  returns the item before the soil appears.
- **Matching:** `prefab` compares the deployed item's id (`farm_plow_item`,
  `birdtrap`). Without a filter any deployable counts.
- **Overlap with `plant`:** planting a dug bush or a seed is also a deploy and
  fires `deployitem`, so a `plant` row and a `deploy` row can both see the same
  action. Use `plant` when the mission means planting; `deploy` when it means
  putting an item down.
- **Not for:** structures placed from the build menu (campfire, firepit,
  Science Machine) — those fire `buildstructure` only. Use `build`.
- **Icon:** the item's own art (`farm_plow_item`); an unfiltered row has no
  single item, so `icon` can point at one.

```lua
{ type = "deploy", prefab = "farm_plow_item", count = 1, label = "Use a Garden Digamajig" }
{ type = "deploy", count = 1, icon = "birdtrap", label = "Deploy something" }
```

### `kill`

Kill `count` creatures.

| Field | Required | Default |
|---|---|---|
| `prefab` | yes | — |
| `count` | yes | — |

- **Completes when:** the player is credited with killing `count` of `prefab`.
- **Trigger:** the `killed` player event; `data.victim.prefab` is compared.
- **Icon:** `prefab`.

```lua
{ type = "kill", prefab = "spider", count = 5, label = "Kill spiders" }
```

### `trap_catch`

Check `count` traps that hold a catch.

| Field | Required | Default |
|---|---|---|
| `prefab` | no | any catch |
| `count` | yes | — |

- **Completes when:** the player checks a sprung trap that actually caught
  something, `count` times. A sprung trap that caught nothing (it disarmed
  safely, or the catch was already removed) does not count, and the objective
  counts the player's **checks**, not the moment the trap springs.
- **Trigger:** the `guidedmissions_trapchecked` player event, pushed by
  `modmain.lua`'s `trap` post-init from `Trap:Harvest(doer)` (the CHECKTRAP
  action). The payload is `{ loot = <the trap's loot prefabs> }`.
- **Matching:** `prefab` is compared against the trap's **loot**, not the
  creature. An inventory-item catch stores the creature itself, so
  `prefab = "rabbit"` works; a lootdropper catch stores its drops, so filter
  the drop instead (`froglegs` for a frog, `silk`/`monstermeat` for a spider).
  Without `prefab`, any catch counts.
- **Icon:** `prefab` when set, otherwise the `trap` item.

```lua
{ type = "trap_catch", prefab = "rabbit", count = 3, label = "Catch rabbits" }
{ type = "trap_catch", prefab = "froglegs", count = 2, label = "Trap frogs" }
{ type = "trap_catch", count = 1, label = "Check a trap with a catch" }
```

### `sleep`

Enter a sleeping bag `count` times.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any sleeping bag |
| `icon` | no | the matched bed, otherwise `tent` |

- **Completes when:** the player gets into a tent, siesta hut, or bedroll,
  `count` times.
- **Trigger:** the `guidedmissions_slept` player event, pushed by
  `modmain.lua`'s `sleepingbaguser` post-init from
  `SleepingBag:DoSleep(doer)` (`components/sleepingbag.lua:61-73`). The payload
  is `{ bed = <the bed entity> }`.
- **Entry, not wake-up:** credit lands the moment the player enters. Waking
  early, being woken by fire, or a starved sleep still counts.
- **Matching:** without `prefab`, any sleeping bag counts. Set
  `prefab = "tent"` to require a tent specifically (the bed entity's prefab is
  matched), or `"siestahut"` for the lean-to.
- **Icon:** the matched bed's build-menu art when `prefab` is set (`tent`,
  `siestahut`, `bedroll_straw`, ...), otherwise the tent (`tent`). `icon`
  overrides either.

```lua
{ type = "sleep", prefab = "tent", count = 1, label = "Sleep in a tent" }
{ type = "sleep", count = 2, label = "Sleep in a bed" }
```

### `reach_stat`

Reach a threshold on a stat, read live.

| Field | Required | Default |
|---|---|---|
| `stat` | yes | — (`"health"`, `"sanity"`, `"hunger"`, `"wetness"` or `"temperature"`) |
| `threshold` | yes | — (for example `">=75"` or `"<0"`) |
| `icon` | no | `heart` / `brain` / `hunger` |

- **Completes when:** the player's stat meets the comparison. The counter shows
  the current value against the threshold: `40/75%` for the percentage stats and
  `35/70°` for temperature.
- **Live, not accumulated:** progress mirrors the current stat and can fall as
  well as rise. It refreshes on `healthdelta`/`sanitydelta`/`hungerdelta` and
  once per second; wetness and temperature are read on the 1-second poll (their
  components emit every frame, which is too often to forward).
- **Threshold syntax:** the same strings emergency conditions use — `<`, `<=`,
  `>`, `>=` followed by a value, with optional whitespace. Health, sanity, hunger
  and wetness use 0-100; temperature uses raw degrees and may be negative
  (`"<0"` freezing, `">70"` overheating). A malformed or out-of-range threshold
  never completes.
- **Already true:** if the condition holds when the mission starts, it completes
  immediately (like `survive`'s past day). Emergencies avoid this because their
  trigger sits on the unsafe side of the goal threshold.
- **Emergency goal rows:** a stat emergency's single required objective is a
  `reach_stat` whose `stat` and `threshold` match the emergency's `resolve`
  condition (the harness enforces this). The emergency still ends on the resolve
  condition, not on objective completion. A hound-wave emergency has no required
  row.
- **Icon:** the HUD heart for health, brain for sanity and stomach for hunger;
  temperature and wetness rows are text-only unless `icon` is set.

```lua
{ type = "reach_stat", stat = "health", threshold = ">=75", label = "Get back to 75% health" }
{ type = "reach_stat", stat = "sanity", threshold = ">=50", label = "Get sanity back to 50%" }
{ type = "reach_stat", stat = "hunger", threshold = ">=50", label = "Get back to 50% hunger" }
{ type = "reach_stat", stat = "wetness", threshold = "<=20", label = "Dry off to 20%" }
{ type = "reach_stat", stat = "temperature", threshold = ">=15", label = "Warm up to 15°" }
```

### `equip`

Have a matching item currently equipped.

| Field | Required | Default |
|---|---|---|
| `prefab` | no | any item |
| `category` | no | any (`"weapon"` / `"tool"` / `"armor"`) |
| `slot` | no | any (`"hands"` / `"head"` / `"body"` / `"beard"`) |
| `icon` | no | `prefab`, or the category default |

- **Completes when:** a matching item is in one of the player's equipment
  slots. It is a **live** check, like `reach_stat`: the row is checked while the
  item is worn and unchecks when it is removed. It refreshes on the `equip` /
  `unequip` events and once per second.
- **No `count`:** the row is binary (`0/1`). Setting `count` is rejected by the
  validation.
- **Matching:** all fields that are set must match (AND). With none set, any
  equipped item counts.
  - `prefab` compares the equipped item's id (`spear`, `armorwood`, `backpack`).
  - `category = "weapon"` matches the vanilla `weapon` tag; `"tool"` matches the
    `tool` tag; `"armor"` matches any item with an `armor` component. There is
    no vanilla `armor` tag. Categories are traits, not exclusive classes: an axe
    and a pickaxe carry both `weapon` and `tool`, so they satisfy either.
    The `weapon` tag means "has a weapon component", which includes a few
    utility items that can swing (compass, brush, bug net); use `prefab` when
    the mission means one specific weapon.
  - `slot` matches the equipment slot (`EQUIPSLOTS` in DST). Backpacks and body
    armour share the `body` slot, so combine `category = "armor"` with a slot
    when the mission must mean armour specifically.
- **Already equipped:** if the player is already wearing a matching item when
  the mission starts, the row starts checked (a mission whose only required row
  is that equip completes at once).
- **Icon:** the named `prefab`; otherwise `spear` for weapons, `axe` for tools,
  `armorwood` (Log Suit) for armour. A slot-only or unfiltered row has no single
  item and is text-only. `icon` overrides.

```lua
{ type = "equip", prefab = "spear", label = "Equip a Spear" }
{ type = "equip", category = "armor", label = "Equip some armor" }
{ type = "equip", category = "armor", slot = "head", label = "Wear a helmet" }
{ type = "equip", slot = "hands", icon = "torch", label = "Hold a light source" }
```

### `survive`

Reach an absolute world day.

| Field | Required | Default |
|---|---|---|
| `day` | yes | — |

- **Completes when:** the world day reaches `day`. The counter shows
  `Day <current>/<target>` and refreshes on the poll.
- **No `prefab`, no counter target, no icon:** the row is text-only and `icon` is
  ignored.
- **Already past:** if the mission starts after that day (for example via
  `c_setmission`), it completes immediately.

```lua
{ type = "survive", day = 5, label = "Survive until day 5" }
```

### `chop`

Fell `count` trees.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `icon` | no | `axe` |

- **Completes when:** a chop swing finishes a tree. Matched by the `tree` tag and
  the CHOP action, with no work left, so any tree prefab counts.
- **Does not count:** partial swings, stumps, digging up stumps, and marble or
  petrified trees (those use the MINE action — see `mine`). A wet tool slipping out
  of the hand fires a targetless working event and is ignored.
- **Icon:** `axe` (override with `icon`).

```lua
{ type = "chop", count = 3, label = "Chop down trees", icon = "axe" }
```

### `mine`

Finish mining `count` nodes with a pickaxe.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `icon` | no | `pickaxe` |

- **Completes when:** a MINE swing finishes a node: boulders, salt rocks, moon rocks,
  marble trees, petrified trees.
- **Does not count:** partial swings, chopping, digging, targetless working events.
- **Icon:** `pickaxe` (override with `icon`).

```lua
{ type = "mine", count = 3, label = "Mine boulders", icon = "pickaxe" }
```

### `eat`

Eat `count` of a specific food.

| Field | Required | Default |
|---|---|---|
| `prefab` | yes | — |
| `count` | yes | — |

- **Completes when:** the player eats `count` items with that prefab.
- **Trigger:** the `oneat` event on the eater; `data.food.prefab` is compared.
- **Icon:** `prefab`.
- **Note:** only edible items can be eaten. Vanilla butterflies are not food; use
  `butterflywings` (what a killed butterfly drops).

```lua
{ type = "eat", prefab = "butterflywings", count = 1, label = "Eat a butterfly wing" }
```

### `heal`

Restore `count` health points.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `icon` | no | `heart` |

- **Completes when:** restored health reaches `count` points.
- **Credit is the requested heal, not the amount that fit under the bar:** a +20
  heal at 148/150 credits 20; a heal at full health counts its full amount as
  overheal. Damage and zero deltas count nothing.
- **Trigger:** the `healthdelta` event. Over-time healing counts point by point.
- **Icon:** `heart`, the HUD health-badge art (like `brain` for sanity); override
  with `icon`, for example `healingsalve`.

```lua
{ type = "heal", count = 10, label = "Restore health", icon = "healingsalve" }
```

### `sanity`

Restore `count` sanity points.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `icon` | no | `brain` |

- **Completes when:** restored sanity reaches `count` points.
- **Any source counts:** flowers, clothing, food, daylight, tent naps, auras, rates.
- **Credit is the requested delta**, recorded by the mod before the stat is clamped,
  so overflow at full sanity still counts. Induced insanity or lunacy forcing the bar
  to 0/full does not hide progress.
- **Trigger:** the `sanitydelta` event.
- **Icon:** `brain` (override with `icon`).

```lua
{ type = "sanity", count = 15, label = "Restore sanity", icon = "brain" }
```

### `pick`

Pick `count` plants of a prefab.

| Field | Required | Default |
|---|---|---|
| `prefab` | yes | — |
| `count` | yes | — |
| `icon` | no | `prefab` |

- **Completes when:** the player picks `count` plants whose prefab matches.
- **Trigger:** the `picksomething` event on the picker; `data.object.prefab` is
  compared. Only picks that produce loot fire it.
- **Icon:** `prefab`. `flower` draws the world flower
  animation; most other plants have no inventory icon, so set `icon` to an item art
  id (e.g. `icon = "berries"` for a berry bush) or leave the row text-only.
- **Interaction with sanity:** picking a normal flower also restores 5 sanity, so a
  `pick` objective and a `sanity` objective can both see the same action.

```lua
{ type = "pick", prefab = "flower", count = 3, label = "Pick flowers", icon = "petals" }
```

### `plant`

Put a plant in the ground `count` times: a seed in tilled soil, or anything
deployed as a plant — a dug bush, grass, sapling or reeds, an acorn or pinecone,
a tree seed or kelp root.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any plantable item |
| `prefabs` | no | — (any of several plantable items; not with `prefab`) |
| `icon` | no | `prefab` (or the first `prefabs` entry), otherwise `seeds` |

- **Completes when:** the player plants `count` things. Two engine paths count,
  and they are the same player intent ("put a plant in the ground"), so they
  share one type:
  - **Seeds in tilled soil** — a soil plot made with a Garden Hoe or the Garden
    Digamajig's plowed soil. Observed through the seed's `farmplantable`
    component (`FarmPlantable:Plant`, called by the `PLANTSOIL` action), plus
    Wormwood's deploy-based seed planting.
  - **Deployed plantables** — dug plants (`dug_berrybush`, `dug_grass`,
    `dug_sapling`, `dug_reeds`, ...) and other items the game tags
    `deployedplant` (acorns, pinecones, tree seeds, kelp roots; the tag is what
    vanilla uses to decide a deploy was a planting).
- **Trigger:** a `guidedmissions_planted` event pushed by the mod, because
  vanilla emits no player event for planting. See `docs/dst-api.md`, "Farming
  and planting".
- **Optional `prefab` filters on the item the player was holding**, not the
  plant that grows: `carrot_seeds`, `seeds`, `dug_berrybush`, `pinecone`. So
  seeds use seed ids (`farm_plant_carrot` is the grown crop and never matches)
  and dug plants use their `dug_` id (`berrybush`, the bush itself, never
  matches).
- **`prefabs` accepts any listed id** when several kinds are the same intent;
  it replaces `prefab` rather than combining with it. The berry bushes are the
  common case: normal `dug_berrybush`/`dug_berrybush2` and juicy
  `dug_berrybush_juicy` (`prefabs/plantables.lua:118-137`).
- **Does not count:** planting in the retired `slow_farmplot`/`fast_farmplot`
  structures (those use the old `grower` component), or dropping a seed on the
  ground.
- **Icon:** the held item's prefab when `prefab` is set (or the first `prefabs`
  entry) — a dug plant has no inventory art, so set `icon = "berries"` for a
  berry bush — otherwise the generic `seeds` art. Override with `icon`.

```lua
{ type = "plant", prefab = "carrot_seeds", count = 3, label = "Plant carrots" }
{ type = "plant", prefab = "dug_berrybush", count = 1, icon = "berries",
  label = "Replant a berry bush" }
{ type = "plant", count = 2, label = "Plant something" }
```

### `fertilize`

Fertilize `count` barren or withered plants.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any pickable plant |
| `self` | no | off (fertilize a plant) |
| `icon` | no | `prefab`; for `self`, `poop`; otherwise `rot` |

- **Completes when:** the player fertilizes a planted bush, grass tuft or reeds
  `count` times. Any fertilizer counts — rot, manure, guano, compost, spoiled
  food.
- **Trigger:** a `guidedmissions_fertilized` event pushed by the mod, because
  vanilla emits no player event for fertilizing. `modmain.lua` wraps
  `Pickable:Fertilize`, the branch the `FERTILIZE` action takes for a pickable
  target. See `docs/dst-api.md`, "Fertilizing".
- **Only barren or withered plants can be fertilized.** Vanilla offers no
  FERTILIZE action on a plant that is still producing, so a freshly planted
  bush or tuft cannot satisfy this objective on demand. A berry bush goes
  barren after `BERRYBUSH_CYCLES` (3) harvests plus up to two random ones, grass
  after `GRASS_CYCLES` (20), and any plant can be fertilized while withered in
  winter. Fertilizing rejuvenates or refills the plant.
- **Matching:** `prefab` filters the **plant that was fertilized**, not the
  fertilizer used: `berrybush`, `berrybush_juicy`, `grass`, `reeds`. Variants
  are separate ids, so `berrybush` does not match `berrybush_juicy`.
- **Does not count:** fertilizing a crop in tilled farm soil or an old
  `slow_farmplot`/`fast_farmplot` — those are other branches of the `FERTILIZE`
  action and are deliberately not reported. The player-themself branch is a
  separate row shape, below.
- **Self-fertilizing (`self = true`):** inverts the row to the player instead of
  a plant. Wormwood applies Rot, Manure, Guano, a Bucket-o'-Poop or any other
  fertilizer to himself to heal; the row completes when he does so. **Any
  fertilizer counts** (all of them heal him through their nutrients), so there
  is no `prefab` filter — setting one is rejected. The heal itself also credits
  a `heal` row through the normal health-delta event.
  - Trigger: a `guidedmissions_self_fertilized` event pushed by the mod's
    `fertilizable` component wrapper.
  - The ordinary plant branch and the self branch never cross-match: a plant
    row ignores self-fertilizing and a self row ignores plants.
- **Icon:** the plant id when `prefab` is set, but plants are world entities
  with no inventory icon, so a filtered row draws nothing unless `icon` names an
  item (`berries` for a berry bush). An unfiltered row shows the `rot` item; a
  `self` row shows the `poop` (Manure) item unless `icon` overrides it.

```lua
{ type = "fertilize", count = 1, label = "Fertilize a plant" }
{ type = "fertilize", prefab = "berrybush", count = 1, icon = "berries",
  label = "Fertilize a berry bush" }
{ type = "fertilize", self = true, count = 1, label = "Fertilize yourself" }
```

### `collect_food`

Hold `count` edible items, optionally of a food type.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefabs` | no | any |
| `foodtype` | no | any |
| `secondaryfoodtype` | no | any |
| `exclude` | no | — |
| `exclude_tags` | no | — |
| `icon` | no | — |

- **Completes when:** peak holdings reach `count` edible items (raw or cooked, stack
  sizes counted). Same never-decreases rule as `collect`.
- **Matching:** any inventory item with an `edible` component whose prefab is in
  `prefabs` (when given) and whose `foodtype`/`secondaryfoodtype` equal the given
  strings exactly, unless the item is dropped by `exclude`/`exclude_tags`.
- **Allow-list:** `prefabs` names the item ids that count, like the same field on
  `plant`. It combines with `foodtype` when both are given. Prefer it over
  `foodtype` when the mission's wording is narrower than vanilla's classification
  — see **Exclusions**.
- **Exclusions:** `exclude` is a list of prefab ids and `exclude_tags` a list of
  entity tags; an item matching either is not counted. Use them when vanilla's
  `FOODTYPE` classification is broader than the mission's wording.
  `foodtype = "VEGGIE"` is the main offender: butterfly wings, moon butterfly
  wings, petals, lightbulbs, foliage, cut lichen and dried plants are all VEGGIE
  (`prefabs/butterflywings.lua:39`, `prefabs/petals.lua:89`,
  `prefabs/lightbulb.lua:69`, ...), as is every Crock Pot dish whose main
  ingredient is a vegetable — those carry the `preparedfood` tag
  (`prefabs/preparedfoods.lua:73`), so `exclude_tags = { "preparedfood" }`
  drops all of them at once. Seasonal event foods (Halloween candy, Winter's
  Feast, carnival corn tea) are VEGGIE too and are not output by the tag, so
  list them by prefab if they matter.
- **Food type values** (`constants.lua:2026-2047`): `GENERIC`, `MEAT`, `VEGGIE`,
  `ELEMENTAL`, `GEARS`, `HORRIBLE`, `INSECT`, `SEEDS` (plural), `BERRY`, `RAW`,
  `BURNT`, `NITRE`, `ROUGHAGE`, `WOOD`, `GOODIES`, `MONSTER`, `LUNAR_SHARDS`,
  `CORPSE`, `MIASMA`. Berries are `VEGGIE` with secondary type `BERRY`; both
  `berries` and `berries_juicy` (and their cooked forms) match
  `secondaryfoodtype = "BERRY"`.
- **Icon:** none by default; set `icon`.
- **No singular `prefab`:** use `prefabs` for one id or several; the validator
  rejects `prefab`. Use `eat` or `collect` for a specific item.
- **Traps:** `foodtype = "VEGGIE"` also counts carrots, mushrooms, corn and every
  other vegetable, so it cannot isolate "berries or carrots" by itself. See
  **Exclusions** for the non-vegetables it also counts.

```lua
{ type = "collect_food", count = 3, foodtype = "VEGGIE", secondaryfoodtype = "BERRY", label = "Collect berries", icon = "berries" }
{ type = "collect_food", count = 5, label = "Collect veggies",
  prefabs = { "carrot", "carrot_cooked", "berries", "berries_cooked",
              "red_cap", "red_cap_cooked" } }
{ type = "collect_food", count = 5, foodtype = "VEGGIE", label = "Collect any veggie",
  exclude = { "butterflywings", "petals", "lightbulb" },
  exclude_tags = { "preparedfood" } }
```

### `cook`

Cook `count` items on a **fire**.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any cooked product |

- **Completes when:** a successful cook on a campfire, firepit, or lighter produces
  an edible item, `count` times. Credit goes to the chef.
- **Optional `prefab`** filters on the cooked product (`cookedmeat`,
  `cookedcarrot`).
- **Not the Crock Pot:** it uses a different component. `cook` never satisfies
  `cookpot` and vice versa.
- **Icon:** the cooked product when `prefab` is set, otherwise the campfire
  (`campfire`). There is no `icon` field — `prefab` is the art id.

```lua
{ type = "cook", count = 1, prefab = "cookedmeat", label = "Cook meat" }
```

### `cookpot`

Start `count` Crock Pot dishes.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any dish |

- **Completes when:** a Crock Pot the player started begins cooking, `count` times.
  DST decides the recipe at that moment, so credit lands at the start — a dish later
  ruined (rain, destruction) still counts.
- **Optional `prefab`** filters on the finished dish id (`meatballs`, `fishsticks`).
  With no filter, any dish counts, including wetgoop.
- **Not filterable by ingredients:** the event carries the ingredient list, but the
  objective matches on the product only.
- **Icon:** the dish when `prefab` is set, otherwise none. There is no `icon`
  field — `prefab` is the art id.

```lua
{ type = "cookpot", count = 1, prefab = "meatballs", label = "Cook meatballs" }
```

### `prototype`

Learn `count` new recipes.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any new recipe |
| `icon` | no | `prefab`, otherwise `blueprint` |

- **Completes when:** the player learns `count` recipes they did not already know —
  prototyping at a crafting station, or learning from a blueprint, recipe scanner, or
  similar teacher.
- **Each recipe counts once.** Recipes already known when the tracker starts are
  seeded from the builder and never count, and vanilla's repeated unlock events for
  placing an already-known structure do not inflate the counter.
- **Optional `prefab`** targets one recipe. This field holds a **recipe id**; in DST
  recipes are named after their product, so `prefab = "goldenaxe"` targets the golden
  axe recipe.
- **No-tech recipes never count:** axe, pickaxe, torch, campfire and other
  `TECH.NONE` recipes are treated as known from the start. Use `craft` for those.
- **Icon:** the recipe id when targeted, otherwise `blueprint` (override with `icon`).

```lua
{ type = "prototype", count = 1, prefab = "goldenaxe", label = "Prototype a Golden Axe", icon = "goldenaxe" }
```

### `tip`

Show an informational row that never completes.

| Field | Required | Default |
|---|---|---|
| `icon` | no | none (text-only) |

- **Completes when:** never. A tip is guidance only: it has no target, no progress,
  and its row never shows a check. Otherwise it is an ordinary row — it carries the
  normal `0/1` counter (a blank counter breaks the tracker's row layout, so it must
  not be blanked).
- **Always optional:** a tip is rendered in the optional group and never gates
  completion, whatever the flag says. Do not author `optional = false`; it is inert
  and the validation rejects it. Every mission still needs at least one real
  required objective.
- **No `prefab`, no `count`:** the type has neither field; the validator rejects
  them.
- **Icon:** none by default, so the row is text-only. Set `icon` when the tip has
  an obvious subject: an inventory art id (`log`), or one of the world-anim ids
  the tracker draws (`flower`, `evergreen_normal`). There is no prefab to derive
  art from.

```lua
{ type = "tip", label = "Stand under a tree to stay dry" }
{ type = "tip", icon = "evergreen_normal", label = "Stand under a tree" }
```

## Choosing between similar types

| Goal | Type |
|---|---|
| Hold items | `collect` / `collect_food` |
| Craft a carryable | `craft` |
| Place a structure | `build` |
| Put down a deployable item (digamajig, bird trap) | `deploy` |
| Eat one specific food | `eat` |
| Hold any food | `collect_food` |
| Cook on a fire | `cook` |
| Make a Crock Pot dish | `cookpot` |
| Learn recipes | `prototype` |
| Chop / mine / pick verbs | `chop` / `mine` / `pick` |
| Plant a seed or replant a dug plant | `plant` |
| Fertilize a bush or grass tuft | `fertilize` |
| Fertilize yourself to heal (Wormwood) | `fertilize` with `self = true` |
| Sleep in a tent | `sleep` |
| Reach a stat percentage | `reach_stat` |
| Have a weapon/tool/armour equipped | `equip` |
| Show a hint row that is not a goal | `tip` |

## Event mapping

| Type | Server signal | Compared value |
|---|---|---|
| `collect` | inventory event, reread next tick | inventory prefab + stack size (peak) |
| `collect_food` | inventory event, reread next tick | `edible` component + stack size (peak), limited by `prefabs`, minus `exclude`/`exclude_tags` |
| `survive` | 1 s poll | world day (`cycles + 1`) |
| `craft` | `builditem`, plus inventory event reread | `data.recipe.name` or `data.item.prefab`; inventory prefab + stack size (peak) |
| `build` | `buildstructure`, plus a 1 s poll for `shared` rows | `data.recipe.name` or `data.item.prefab`; nearby `structure` entities matching `prefab` |
| `deploy` | `deployitem` | `data.prefab` (the deployed item) |
| `kill` | `killed` | `data.victim.prefab` |
| `eat` | `oneat` | `data.food.prefab` |
| `pick` | `picksomething` | `data.object.prefab` |
| `chop` | `working` | finished CHOP work on a non-stump `tree` |
| `mine` | `working` | finished MINE work |
| `heal` | `healthdelta` | positive `amount` |
| `sanity` | `sanitydelta` | recorded requested delta > 0 |
| `cook` | `guidedmissions_cookedfood` (mod pushed) | `product.prefab` |
| `cookpot` | `guidedmissions_stewedfood` (mod pushed) | `product` (a string) |
| `prototype` | `unlockrecipe` | `data.recipe` matched to objective `prefab` (a recipe id), deduplicated |
| `plant` | `guidedmissions_planted` (mod pushed) | `item` (the held item's prefab id) |
| `trap_catch` | `guidedmissions_trapchecked` (mod pushed) | objective `prefab` matched against any entry in `data.loot` |
| `sleep` | `guidedmissions_slept` (mod pushed) | objective `prefab` matched to `data.bed.prefab` |
| `fertilize` | `guidedmissions_fertilized` (mod pushed) | objective `prefab` matched to `data.plant.prefab` |
| `fertilize` (`self = true`) | `guidedmissions_self_fertilized` (mod pushed) | any fertilizer applied to the player |
| `reach_stat` | `healthdelta` / `sanitydelta` / `hungerdelta` + 1 s poll (wetness/temperature: poll only) | live stat value vs objective `threshold` (percent, or degrees for temperature) |
| `equip` | `equip` / `unequip` + 1 s poll | live `inventory.equipslots`, filtered by `prefab`/`category`/`slot` |
| `tip` | none | never completes (no progress, no counter) |

`cookedfood`/`stewedfood`/`planted`/`trapchecked`/`slept`/`fertilized` exist
because vanilla fire cooking, Crock Pot cooking, planting, trap checking, entering
a bed and fertilizing a plant emit no player event; `modmain.lua` post-inits the
`cooker`, `stewer`, `farmplantable`, `deployable`, `trap`, `sleepingbaguser` and
`pickable` components to report them. See `docs/dst-api.md` for the verified
engine behavior behind each row.

## Adding or changing an objective type

1. **`scripts/guidedmissions/objectives.lua`**
   - Add the type to `VALID_TYPES`.
   - Add the icon default in `GetIconPrefab`.
   - Match the event in `GetEventIncrement`; add an initial value in
     `InitialProgress` and reread handling in `ReconcileProgress` if it is
     inventory-derived.
2. **`scripts/guidedmissions/manager.lua`** — listen for a new engine event and
   forward it to `OnObjectiveEvent`; if vanilla emits no usable event, hook the
   component in `modmain.lua` and push a `guidedmissions_*` event.
3. **`tests/manager_test.lua`** — register the type's field requirements
   (`needs_prefab` / `optional_prefab`) and add a fixture to `type_fixtures` for its
   icons and matching rules. The harness fails if any
   `Objectives.VALID_TYPES` entry has no fixture, so this step is enforced.
4. **Docs** — update this file (fields, defaults, icon, event mapping) and the table
   in `README.md`. If you verified new engine behavior, record it in
   `docs/dst-api.md`.
5. **Text** — if the change adds or edits labels, regenerate `languages/en.lua` and
   update every shipped locale (`es`, `pt`, `de`, `zh`); see
   [`localization.md`](localization.md).
6. Run `./verify`, then confirm in game with a human test — rendering and netvar
   replication are not covered offline.
