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

Missions run in file order. Each player advances independently after a 3-second
"won" hold. The last mission is followed by a terminal "All Missions Complete" card.

## Emergency missions

Pop-up emergencies are a separate, unordered collection in
[`emergencies.lua`](../scripts/guidedmissions/emergencies.lua). They reuse the objective
schema on this page, but each entry has `trigger`/`resolve` conditions instead of a chain
position, and **every emergency objective must set `optional = true`** — the card
resolves on a stat threshold, never on objective completion. See
[`emergencies.md`](emergencies.md) for the full schema.

## How progress is counted

There are three mechanisms:

- **Inventory-derived (reread on inventory events):** `collect`, `collect_food`.
  Any player `itemget`, `gotnewitem`, `newactiveitem`, or `setoverflow` schedules
  one reread on the next tick and a burst of pickups coalesces into that one read.
  Progress is the **peak holding** seen since the mission started — spending or
  dropping items never removes credit, but picking items up later can raise it.
  The inventory at the moment the mission starts counts as the starting value.
- **World-state (polled every second):** `survive` reads the world day. Polling
  runs only for missions that contain a survive objective.
- **Event-driven:** everything else. Each event adds an increment (usually 1, but
  `heal`/`sanity` add points).

Rows render as `label`, icon, `progress/count`, and a green check when done. Optional
rows sit in their own group below an `Optional` heading and use a dimmer colour. During
the completion hold the required rows are shown checked; optional rows show their real
state, so an unfinished optional objective is visibly left unchecked.

## Icons

The server writes an icon id per row; the HUD resolves it as:

1. `brain` → the HUD sanity-badge art (`images/global_redux.xml`).
2. `heart` → the HUD health-badge art (`images/global_redux.xml`).
3. `flower` → the world flower animation (flowers have no inventory icon).
4. Any other id `<id>` → `images/inventoryimages*.xml` lookup for `<id>.tex`.

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

Craft `count` inventory items.

| Field | Required | Default |
|---|---|---|
| `prefab` | yes | — |
| `count` | yes | — |

- **Completes when:** the player crafts an item whose recipe or product id is
  `prefab`, `count` times.
- **Trigger:** the `builditem` player event, fired for products that go into the
  inventory (torch, spear, axes, armour).
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

- **Completes when:** the player places the structure `prefab`, `count` times.
- **Trigger:** the `buildstructure` player event.
- **Icon:** `prefab`.
- **Not for:** carryable products — those are `craft`.

```lua
{ type = "build", prefab = "firepit", count = 1, label = "Build a Fire Pit" }
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
- **Icon:** none — the row is text-only, and `icon` is ignored.

```lua
{ type = "sleep", prefab = "tent", count = 1, label = "Sleep in a tent" }
{ type = "sleep", count = 2, label = "Sleep in a bed" }
```

### `reach_stat`

Reach a threshold on a stat, read live.

| Field | Required | Default |
|---|---|---|
| `stat` | yes | — (`"health"` or `"sanity"`) |
| `threshold` | yes | — (for example `">=75"`) |
| `icon` | no | `heart` / `brain` |

- **Completes when:** the player's stat meets the comparison. The counter shows
  the current percentage against the threshold, for example `40/75%`.
- **Live, not accumulated:** progress mirrors the current stat and can fall as
  well as rise. It refreshes on `healthdelta`/`sanitydelta` and once per second.
- **Threshold syntax:** the same strings emergency conditions use — `<`, `<=`,
  `>`, `>=` followed by a 0-100 value, with optional whitespace. A malformed
  threshold never completes.
- **Already true:** if the condition holds when the mission starts, it completes
  immediately (like `survive`'s past day). Emergencies avoid this because their
  trigger sits below the goal threshold.
- **Emergency goal rows:** an emergency's single required objective is a
  `reach_stat` whose `stat` and `threshold` match the emergency's `resolve`
  condition (the harness enforces this). The emergency still ends on the resolve
  condition, not on objective completion.
- **Icon:** the HUD heart for health and brain for sanity; `icon` overrides.

```lua
{ type = "reach_stat", stat = "health", threshold = ">=75", label = "Get back to 75% health" }
{ type = "reach_stat", stat = "sanity", threshold = ">=50", label = "Get sanity back to 50%" }
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

Plant `count` seeds in tilled farm soil.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `prefab` | no | any seed |
| `icon` | no | `prefab`, otherwise `seeds` |

- **Completes when:** the player plants a seed into a tilled soil plot (made
  with a Garden Hoe or the Garden Digamajig's plowed soil), `count` times.
- **Trigger:** a `guidedmissions_plantedseed` event pushed by the mod, because
  vanilla emits no player event for planting. The seed's `farmplantable`
  component (`FarmPlantable:Plant`, called by the `PLANTSOIL` action) is
  observed in `modmain.lua`; Wormwood's deploy-based planting is observed
  through the `deployable` component. See `docs/dst-api.md`, "Farming".
- **Optional `prefab` filters on the seed the player planted**, not the crop
  that grows: `carrot_seeds`, `pumpkin_seeds`, or the generic `seeds`. Vanilla
  plant prefabs are named `farm_plant_<crop>` (`farm_plant_carrot`) and are not
  what this field matches.
- **Does not count:** planting in the retired `slow_farmplot`/`fast_farmplot`
  structures (those use the old `grower` component), or dropping a seed on the
  ground.
- **Icon:** the seed prefab when `prefab` is set, otherwise the generic `seeds`
  art (override with `icon`). The planted crop itself has no inventory icon.

```lua
{ type = "plant", prefab = "carrot_seeds", count = 3, label = "Plant carrots" }
```

### `collect_food`

Hold `count` edible items, optionally of a food type.

| Field | Required | Default |
|---|---|---|
| `count` | yes | — |
| `foodtype` | no | any |
| `secondaryfoodtype` | no | any |
| `icon` | no | — |

- **Completes when:** peak holdings reach `count` edible items (raw or cooked, stack
  sizes counted). Same never-decreases rule as `collect`.
- **Matching:** any inventory item with an `edible` component whose
  `foodtype`/`secondaryfoodtype` equal the given strings exactly.
- **Food type values** (`constants.lua:2026-2047`): `GENERIC`, `MEAT`, `VEGGIE`,
  `ELEMENTAL`, `GEARS`, `HORRIBLE`, `INSECT`, `SEEDS` (plural), `BERRY`, `RAW`,
  `BURNT`, `NITRE`, `ROUGHAGE`, `WOOD`, `GOODIES`, `MONSTER`, `LUNAR_SHARDS`,
  `CORPSE`, `MIASMA`. Berries are `VEGGIE` with secondary type `BERRY`; both
  `berries` and `berries_juicy` (and their cooked forms) match
  `secondaryfoodtype = "BERRY"`.
- **Icon:** none by default; set `icon`.
- **No `prefab`:** this type has no prefab field; the validator rejects one. Use
  `eat` or `collect` for a specific item.
- **Traps:** `foodtype = "VEGGIE"` also counts carrots, mushrooms, corn and every
  other vegetable, so it cannot isolate "berries or carrots" by itself.

```lua
{ type = "collect_food", count = 3, foodtype = "VEGGIE", secondaryfoodtype = "BERRY", label = "Collect berries", icon = "berries" }
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
- **Icon:** the cooked product when `prefab` is set, otherwise none. There is no
  `icon` field — `prefab` is the art id.

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

## Choosing between similar types

| Goal | Type |
|---|---|
| Hold items | `collect` / `collect_food` |
| Craft a carryable | `craft` |
| Place a structure | `build` |
| Eat one specific food | `eat` |
| Hold any food | `collect_food` |
| Cook on a fire | `cook` |
| Make a Crock Pot dish | `cookpot` |
| Learn recipes | `prototype` |
| Chop / mine / pick verbs | `chop` / `mine` / `pick` |
| Plant seeds in tilled soil | `plant` |
| Sleep in a tent | `sleep` |
| Reach a stat percentage | `reach_stat` |

## Event mapping

| Type | Server signal | Compared value |
|---|---|---|
| `collect` | inventory event, reread next tick | inventory prefab + stack size (peak) |
| `collect_food` | inventory event, reread next tick | `edible` component + stack size (peak) |
| `survive` | 1 s poll | world day (`cycles + 1`) |
| `craft` | `builditem` | `data.recipe.name` or `data.item.prefab` |
| `build` | `buildstructure` | `data.recipe.name` or `data.item.prefab` |
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
| `plant` | `guidedmissions_plantedseed` (mod pushed) | `seed` (a prefab id string) |
| `trap_catch` | `guidedmissions_trapchecked` (mod pushed) | objective `prefab` matched against any entry in `data.loot` |
| `sleep` | `guidedmissions_slept` (mod pushed) | objective `prefab` matched to `data.bed.prefab` |
| `reach_stat` | `healthdelta` / `sanitydelta` + 1 s poll | live stat percentage vs objective `threshold` |

`cookedfood`/`stewedfood`/`plantedseed`/`trapchecked`/`slept` exist because vanilla
fire cooking, Crock Pot cooking, seed planting, trap checking and entering a bed emit
no player event; `modmain.lua` post-inits the `cooker`, `stewer`, `farmplantable`,
`deployable`, `trap` and `sleepingbaguser` components to report them. See
`docs/dst-api.md` for the verified engine behavior behind each row.

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
5. Run `./verify`, then confirm in game with a human test — rendering and netvar
   replication are not covered offline.
