# Guided Missions

A configurable mission-chain mod for **Don't Starve Together**. It gives each player an
ordered list of objectives and a small HUD tracker, so a group can follow a guided
playthrough. Mission progress is server-authoritative and saved per player.

## Install

1. Copy this folder into your DST mods directory, for example:
   `C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\mods\dst-mission-mod`
2. Start DST, open **Mods**, and enable **Guided Missions**.
3. Start or resume a world. All clients must have the mod installed.
4. Optional: use **Mods → Configure** to toggle the tracker or completion announcements.

## Configure missions

Missions live in [`scripts/guidedmissions/missions.lua`](scripts/guidedmissions/missions.lua).
Missions run top to bottom. Restart the server (or disable/enable the mod) after editing.

```lua
{
    id = "gather_wood",                       -- keep IDs stable between edits
    title = "Gather Wood",
    objectives = {
        { type = "collect", prefab = "log", count = 10, label = "Collect 10 logs" },
    },
}
```

Supported objective types:

| Type      | Fields            | Completes when |
|-----------|-------------------|----------------|
| `collect` | `prefab`, `count` | the player has held `count` of the prefab |
| `craft`   | `prefab`, `count` | the player crafts `count` of an inventory item |
| `build`   | `prefab`, `count` | the player builds `count` of a structure in the world |
| `kill`    | `prefab`, `count` | the player kills `count` of the prefab |
| `survive` | `day`             | the world reaches that day |
| `chop`    | `count`           | the player fells `count` trees (any tree prefab, axe/chop action only) |
| `eat`     | `prefab`, `count` | the player eats `count` of the food prefab |
| `heal`    | `count`           | the player restores `count` health (requested amounts, including overheal) |
| `sanity`  | `count`           | the player restores `count` sanity (any source, including overflow at full sanity) |
| `mine`    | `count`           | the player finishes mining `count` nodes with a pickaxe |
| `pick`    | `prefab`, `count` | the player picks `count` of the plant prefab |
| `collect_food` | `count`, optional `foodtype`/`secondaryfoodtype` | the player has held `count` edible items (peak holdings, like `collect`) |
| `cook`    | `count`, optional `prefab` | the player cooks `count` food items on a fire |
| `cookpot` | `count`, optional `prefab` | the player starts cooking `count` dishes in a Crock Pot (optional dish filter) |
| `prototype` | `count`, optional `recipe` | the player learns `count` new recipes (station prototyping or blueprints) |

`label` is optional. `collect` reads the player's inventory, so the starting
inventory counts and stacked pickups register; the progress is peak holdings, so
spending or dropping items later does not remove credit. `craft` and `build` are
deliberately separate: torches, spears, and other carryable products are `craft`;
firepits, Science Machines, walls and other placed objects are `build`. Using the
wrong type for a prefab means that objective never completes. Prefab ids are the
game's internal ids (e.g. `log`, `torch`, `firepit`, `researchlab` for the Science
Machine).

`chop` counts trees felled, not individual axe swings, and matches any tree prefab by
tag — stumps, dug roots, and mined marble/petrified trees do not count. `eat` compares
the eaten food's prefab id; note that vanilla DST butterflies are not food (they have no
`edible` component), so an `eat` objective for `butterfly` never completes. Use
`butterflywings` (what a killed butterfly drops) or a food prefab added by another mod.

`heal` and `sanity` credit the **amount requested by the heal, not the points that fit
under the bar**: a +20 heal eaten at 148/150 counts 20, and a heal at full health counts
its full amount as overheal, so the objective can be completed without first being hurt.
Healing over time (beds, hot springs, elixirs, sanity auras and rates) also counts, point
by point. For sanity, **any** gain counts — picking flowers, a top hat, daylight, a tent
nap, and so on. Use `pick` with `prefab = "flower"` if the mission should specifically
require flower picking; use `sanity` when the goal is the amount restored regardless of
source. Induced insanity or lunacy does not hide progress: the mod reads the requested
delta rather than the bar, which those effects force to 0 or full.
`mine` credits a completed `MINE` work action, so any pickaxe-mined node counts — boulders,
salt/moon rocks, marble and petrified trees — while partial swings and chopping/digging do
not. `pick` matches the picked plant's prefab; for flowers use `prefab = "flower"`. Picking a
normal flower restores 5 sanity as part of the pick (`prefabs/flower.lua:57`), while eating
the petals restores only 1 health and no sanity — so a "pick flowers to restore sanity"
mission should use `pick`, not `eat` on the petals. A `pick` row for `flower` draws the
world flower's own animation (the same art the player sees in the world; flowers have no
inventory icon). Other plants have no built-in icon, so set the optional `icon` field to
an item id (e.g. `icon = "berries"`) if you want one on the row. `icon = "brain"` on a
`sanity` row draws the HUD's sanity brain (the same art as the status badge); without it
the row is text-only.

`collect_food` counts any carried item with an `edible` component — raw or cooked — using
the same peak-holdings rule as `collect`. It accepts an optional food-type filter. Food
types are strings: berries are main type `VEGGIE` with secondary type `BERRY`, and both
`berries` and `berries_juicy` (and their cooked forms) use that pair — so
`{ type = "collect_food", count = 3, secondaryfoodtype = "BERRY" }` counts either berry
variety.
`foodtype = "VEGGIE"` is broader: it counts carrots, berries, mushrooms, corn, and every
other vegetable, so it cannot isolate "berries or carrots" on its own. With neither filter,
any food counts.

`cook` counts successful cooking on a **fire** (campfire, firepit, lighter) — the mod hooks
the `cooker` component to report it. The crockpot is deliberately not included; it uses a
different component (`stewer`). Any cooked product that is edible counts; the optional
`prefab` field narrows it to one cooked product (e.g. `prefab = "cookedmeat"`).

`cookpot` is the Crock Pot counterpart: it counts dishes when the pot starts cooking, which
is when DST decides the recipe. Credit goes to the player who started the pot, and the
optional `prefab` filters on the dish (`prefab = "meatballs"`). With no filter, any dish
counts, including wetgoop. Because credit lands at the start, a dish later ruined by rain
is still counted. Fire cooking and crockpot cooking are deliberately separate types:
`cook` never satisfies `cookpot`, and vice versa.

`prototype` counts recipes the player newly learns, using the same `unlockrecipe` signal
Klei uses for its `character.prototyped` metric. That includes prototyping an item at a
crafting station for the first time and learning from blueprints, recipe scanners, and
similar teachers. Each recipe counts once; recipes the player already knew when the tracker
started are seeded from the builder and never count, and vanilla's repeated unlock events
for placing an already-known structure do not inflate the counter. The row uses the
blueprint item's icon by default; a targeted `recipe` shows that product's icon instead,
and an explicit `icon` field overrides either. The optional `recipe` field targets one
recipe id (e.g. `recipe = "goldenaxe"`). Because pre-learned recipes do not
count, a prototype mission placed late in the chain needs recipes the player has not learned
yet — `c_resetmissions()` does not forget recipes.

Important: **no-tech recipes never fire this event.** Axe, pickaxe, torch, campfire and
other `TECH.NONE` recipes are considered known from the start, so building one for the
first time does not count as a prototype (and `prototype` with `recipe = "axe"` would never
complete). Use `craft` for those, e.g. `{ type = "craft", prefab = "axe", count = 1 }`.

## Retest with admin commands

As an admin (the host in a locally hosted world), open the debug console with `~`
and run:

- `c_resetmissions()` — restart your own chain from mission 1.
- `c_setmission(n)` — jump straight to mission `n` (1-based, in the order missions
  appear in `missions.lua`), e.g. `c_setmission(5)`. One past the last mission shows
  the completion state.

Both names autocomplete in the console. An in-game admin's console defaults to
**Remote** execution (toggle with Ctrl), which runs the command on the server where
the mission state lives; local execution forwards it over an RPC, so both work.

Both commands only change tracker state — the world and your inventory are untouched.
Your inventory counts as starting inventory for `collect` objectives, exactly like a
fresh mission, so a jump may complete immediately if you already carry the required
items.

## How it plays

- The mod is purely informational: it never grants items, changes stats, or alters
  gameplay. It only observes what players do and shows guidance.
- The tracker appears at the top-left for every player, showing the active mission and
  objective progress.
- Missions advance automatically when all objectives are complete.
- Mission completions are announced in chat (can be disabled). Mission starts are not
  announced — the tracker already shows the active mission.
- After the last mission the tracker shows **All missions complete!**
- Progress is per player and survives save/load.

## Troubleshooting

- **No tracker:** make sure the mod is enabled on the client and `Mission Tracker` is on
  in the mod configuration. Check `client_log.txt` for errors.
- **Can't join a modded server:** every client needs this mod (`all_clients_require_mod`).
- **Mission progress looks stale:** mission data is loaded at startup; restart the world
  after editing `missions.lua`.
- **Testing persistence:** use `c_save()`, then rejoin. To restart the mission chain
  without regenerating the world, run `c_resetmissions()` in the console as an admin.

## Known limitations

- Progress is per player; there is no shared or team mission state.
- `collect` is polled from the inventory once a second and only counts the player's
  inventory and backpack, not chests; items crafted and consumed within the same
  second may not be counted.
- The tracker is text-only with a fixed layout; long objective lists can overflow.
- Completion is announced globally, with no per-player popup.
- No localization, no custom icons, no mission editor UI.

## Roadmap

Mission sets selectable via mod options; an admin command to skip the current mission;
shared progress; `visit`, `feed`, and `give item` objective types; an external JSON
mission loader.
