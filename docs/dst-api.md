# Verified DST API notes

Facts checked against the installed game scripts on 2026-10-31. Read this before
touching netvars, the HUD widget, or server event hooks — the details below are
expensive to re-derive and several are non-obvious. Most bullets cite a file (and
line where useful); if a game update moves a line number, re-check the source before
trusting a claim rather than assuming it still holds.

## Source of truth: the game's own scripts

```
C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\data\databundles\scripts.zip
```

Open a single file without extracting the archive:

```bash
unzip -p "<steam>/data/databundles/scripts.zip" scripts/components/builder.lua
```

To search, extract **once** and grep the directory:

```bash
unzip -q "<steam>/data/databundles/scripts.zip" -d /tmp/dst-scripts
grep -rn "net_string(" /tmp/dst-scripts/scripts --include="*.lua" | head
```

Do not loop `unzip -p` over every entry in the archive: it spawns thousands of
processes, takes minutes, and is the slowest way to answer anything.

## Fast lookup — which file answers which question

| Question | Look at |
|---|---|
| How the mod environment works | `scripts/mods.lua` (`CreateEnvironment`, ~line 263) |
| Why an undeclared global errored | `scripts/strict.lua` |
| `AddPlayerPostInit`, `AddPrefabPostInit`, `GetModConfigData` | `scripts/modutil.lua` |
| Player event sources | `scripts/components/inventory.lua`, `builder.lua`, `combat.lua` |
| Farming / planting seeds | `scripts/components/farmplantable.lua`, `scripts/actions.lua` (`PLANTSOIL`), `scripts/componentactions.lua` |
| Fertilizing a bush/grass | `scripts/actions.lua` (`ACTIONS.FERTILIZE.fn`), `scripts/components/pickable.lua`, `scripts/components/fertilizer.lua`, `scripts/componentactions.lua` |
| Components (general) | **`scripts/components/`** — not `scripts/` |
| `player.HUD` and HUD construction | `scripts/prefabs/player_common.lua`, `scripts/screens/playerhud.lua` |
| UI globals (`DEFAULTFONT`, `ANCHOR_*`) | `scripts/fonts.lua`, `scripts/constants.lua` |
| Widget methods | `scripts/widgets/widget.lua`, `text.lua`, `image.lua` |
| Netvar types and dirty-event docs | `scripts/netvars.lua` (constructors are engine-bound) |
| Atlases and `.tex` files | `data/databundles/images.zip` (not `data/images/`) |
| Which font to use for what | `scripts/fonts.lua`, `widgets/redux/craftingmenu_details.lua` |
| Item icon atlas for a prefab | `scripts/simutil.lua` (`GetInventoryItemAtlas`) |
| Wood/panel/checkmark textures | `data/databundles/images.zip` + the asset table in `scripts/prefabs/global.lua` |
| Playing a UI sound | `scripts/frontend.lua` (`GetSound`), `scripts/haptics.lua` (UI event list) |
| Tweening / sliding a widget | `scripts/widgets/widget.lua` (`MoveTo`), `scripts/components/uianim.lua` |
| Client-side saved preferences | `scripts/mainfunctions.lua` (`SetPersistentString`), `scripts/craftingmenuprofile.lua` |
| Performance / profiling | `scripts/profiler.lua`, `perfutil.lua`, `consolecommands.lua` |
| Translation / locale codes | `scripts/languages/loc.lua`, `scripts/translator.lua`, `scripts/main.lua` (boot order), `scripts/modutil.lua` (`LoadPOFile`) |

If a signature is in doubt, check here rather than guessing — DST's API is loosely
documented and version-dependent.

## Mod metadata (`modinfo.lua`)

- `api_version = 10` for DST.
- Requires `dst_compatible = true`, `all_clients_require_mod = true`, `client_only_mod = false`.
- **Mod icon** (verified 2026-11-09): set `icon_atlas = "icon/modicon.xml"` and
  `icon = "modicon.tex"` in `modinfo.lua` (this repo keeps both in `icon/`;
  `icon` is the atlas's Element name, not a path). `icon_atlas` is a path from
  the mod root; `modindex.lua:542-556` resolves them, derives `iconpath` from the
  atlas directory (`modindex.lua:544`:
  `iconpath = dirname(atlaspath).."/"..icon`), so the pair may live in a
  subfolder as long as both files sit together. The `.png` is build input only —
  `screens/modsscreen.lua:1043-1044` draws `SetTexture(icon_atlas, icon)` and
  `:1321-1324` preloads just the atlas and `.tex`; the game never loads the PNG.
  Both icon files must be non-empty and present, or the game **clears all three
  fields with a `WARNING: icon paths for mod ... are not valid` print**.
  No `Assets` entry is needed in `modmain.lua` — `ModsScreen:LoadModInfoPrefabs`
  (`screens/modsscreen.lua:1321`) preloads the atlas and image itself.
- The Mods-menu detail pane draws the icon at **102×102**
  (`screens/modsscreen.lua:1043-1048`); if `icon`/`icon_atlas` are unset (or invalid)
  it falls back to `images/ui.xml` / `portrait_bg.tex`. Design for legibility at that
  size — thin lines and small text disappear.
- File format: the game loads `modicon.tex` (KTEX, compiled with ktools `ktech`) plus a
  hand-writable single-element atlas:
  `<Atlas><Texture filename="modicon.tex" /><Elements><Element name="modicon.tex" u1="0.00390625" u2="0.99609375" v1="0.00390625" v2="0.99609375" /></Elements></Atlas>`
  (the u/v insets are 1/256). Source images of 256×256 and 128×128 both ship in
  installed workshop mods; the menu downscales to 102 either way.
- There is **no parchment/scroll/paper texture** in the base UI atlases
  (`images.zip` has no matching `.tex` in `images/ui.xml` or
  `images/crafting_menu.xml`; verified 2026-11-09). An icon that should reuse
  vanilla art can be composed offline from the pieces the tracker already draws:
  card frame `images/crafting_menu.xml` → `backing.tex`, `side.tex`, `top.tex`,
  `bottom.tex` (dark carved wood, not paper); green `checkmark.tex`,
  `line_horizontal_white.tex`, `arrow2_right.tex`, `red_star.tex`,
  `yellow_exclamation.tex` and `pinslot_fg_pin.tex` in `images/ui.xml` /
  `images/crafting_menu.xml`.
- This repo's icon (`icon/modicon.png` → `icon/modicon.tex`) is the vanilla
  `book_research_station.tex` item icon (the Everything Encyclopedia book) from
  `images/inventoryimages1.xml` (64×64 source; the `inventoryimages.xml` lists the
  same names but has no matching `.tex`), scaled 3× and placed inside the vanilla
  default frame `images/ui.xml` → `portrait_bg.tex` (128×128, upscaled 2×). That is
  the same frame the Mods screen falls back to when `icon`/`icon_atlas` are unset.
  `tools/make_modicon.py` builds both files into `icon/`; it carries a minimal DXT5 KTEX writer
  because ktools (`ktech`) is not installed on this machine. The KTEX header is the
  known-good `0xFFFD2220` from an installed mod; mip data is stored bottom-up.
- **KTEX alpha is premultiplied.** `tests/preview/render.py` (`decode_dxt5_block`,
  ~line 69) un-premultiplies partial-alpha texels when decoding
  (`r = r * 255 // a`) and produces no clipped values against vanilla atlases.
  Consequence for any texture generated outside ktech: multiply RGB by alpha
  before DXT5 encoding, or soft edges render too bright in-game. The checked-in
  PNG stays straight-alpha; only the `.tex` data is premultiplied.

## Mod environment and strict mode

- `mods.lua` (`CreateEnvironment`) sets `env.GLOBAL = _G` and `env.require = require`,
  then runs `modmain.lua` with `setfenv` into that env.
- `require()`d files (everything under `scripts/`) run in the **standard global env**,
  not the mod env, so `GLOBAL` is undeclared there.
- `scripts/strict.lua` turns undeclared global reads/writes into hard errors, so
  `local GLOBAL = GLOBAL` in a module fails the whole mod with
  `variable 'GLOBAL' is not declared`. Use `local GLOBAL = _G` in those files:
  it is the same table that modmain's `GLOBAL` points at.
- **The mod env is a whitelist with no `_G` fallback** (`mods.lua`
  `CreateEnvironment`, ~line 263). It contains only `pairs`, `ipairs`, `print`,
  `math`, `table`, `type`, `string`, `tostring`, `require`, `Class`, plus the mod
  globals injected by `modutil.InsertPostInitFunctions` and `GLOBAL = _G`; there is
  no metatable. `tonumber` in particular is **absent**. A function defined in
  `modmain.lua` keeps this env when it is later called from the debug console, so a
  console command that calls bare `tonumber` dies with
  `attempt to call global 'tonumber' (a nil value)` even though the same call works
  in a `require()`d module (those run in the standard `_G`). Reach missing base
  functions through `GLOBAL` (verified in-game 2026-11-07: this broke
  `c_setmission(n)` while `c_resetmissions()` worked).
- `AddPlayerPostInit` is defined in `modutil.lua` (~line 586) as
  `AddPrefabPostInitAny` plus a `player` tag filter; it runs on server and client.

## Player hooks and events

- Event payloads, all pushed on the player that acted:
  - `itemget` → `{ item = <entity>, slot = ..., src_pos = ... }`, pushed by
    `components/inventory.lua` at two places, and neither matches "the player just
    acquired something":
    - `Inventory:GiveItem` pushes it only when the item lands in an *empty*
      inventory slot (line 1151). A pickup that merges into an existing stack goes
      through `stackable:Put` and fires **nothing**, so events alone under-count
      repeated pickups of a stackable resource. Harvesting and bush-picking go
      through the same `GiveItem` (`components/pickable.lua` ~486/509,
      `components/harvestable.lua` ~206), which is why stacked bush picks are silent.
    - `Inventory:GiveActiveItem` (line 1020, `slot = nil`) fires it every time an
      item is clicked onto the cursor, and giving it back fires it again — so
      accumulating stack size on `itemget` lets a player inflate a counter by
      clicking their own inventory repeatedly. **Never accumulate collect progress
      from `itemget`.** `collect` objectives are inventory-derived: the manager
      rereads the peak `inventory:ForEachItem` count (see `objectives.lua`
      `ReconcileProgress`), which also survives spending or dropping the items.
  - `gotnewitem` → `{ item, slot }` fires for stack merges too (`inventory.lua:1100`),
    but it *also* fires when a player moves an item into a carried container such as
    their own backpack (`components/container.lua` ~491/508). It is a pickup-sound
    event, not a reliable "acquired something new" signal; do not use it to grant
    collect progress. Use it only as a *trigger* to reread
    `inventory:ForEachItem` (see `objectives.lua` `ReconcileProgress`).
  - **Inventory-gain events (usable as reread triggers).** There is no single
    "inventory changed" event. Four player events cover every way an item can
    join the counted inventory:
    - `itemget` — empty inventory slot (`inventory.lua:1151`) and cursor pickup
      (`:1020`);
    - `gotnewitem` — stack merges, empty slots, and worn-container puts
      (`inventory.lua:1100`, `:1204`; `container.lua:491/508/550`);
    - `newactiveitem` — inventory full, item goes to the cursor
      (`inventory.lua:1254-1256`);
    - `setoverflow` — a body container (backpack) is equipped
      (`inventory.lua:1370`), which brings its contents into `ForEachItem`.
    **Ordering caveat:** `gotnewitem` is pushed *before* the item is placed or
    merged (`inventory.lua:1100` precedes the `stackable:Put` at `:1146`; the
    container paths likewise push before `Put`), so a reread inside the handler
    sees a stale count. Defer it one tick. Removals need no event when progress
    is peak-held.
  - `builditem` → `{ item = <entity>, recipe = <recipe>, skin, prototyper }`, pushed by
    `components/builder.lua` (~line 741) **only when the product has an
    `inventoryitem` component** (torch, tool, most craftables).
  - `buildstructure` → `{ item = <structure>, recipe = <recipe>, skin }`, pushed by
    `components/builder.lua` (~line 821) for products with **no** `inventoryitem`
    component — firepit, researchlab, walls, statues, anything placed into the world.
    Both are pushed on the builder/building player. The manager listens for both;
    the `craft` objective type matches only `builditem` and `build` matches only
    `buildstructure`, so an objective declared with the wrong type never completes.
  - `killed` → `{ victim = <entity>, attacker = <entity>, ... }`, pushed on the
    **attacker/doer**, not the victim (`components/combat.lua:682`, also `actions.lua`).
    Listening on the player is therefore correct for kill objectives.
  - `working` → `{ target = <entity> }`, pushed on the **worker** by
    `components/workable.lua` `WorkedBy_Internal` (~line 148) after the target's
    `workleft` is decremented and before `onfinish` runs, so the target is still valid.
    It fires for every workable action (chop, mine, dig, hammer). **`actions.lua:1352`
    and `:1372` also push `working` with an empty table** when a wet tool slips out of
    the hand — guard `data.target` before using it.
  - `finishedwork` → `{ target = <entity>, action = <action> }`, pushed on the worker
    only when `workleft` reaches 0 (`components/workable.lua` ~line 166). It runs
    **after** the target's `onfinish`, which may have removed the target; prefer
    `working` plus reading `target.components.workable.workleft` when the target might
    disappear (trees survive as stumps, but other workables often do not).
  - **Tree tags:** normal trees add the `tree` tag (`prefabs/evergreens.lua:848`,
    `prefabs/deciduoustrees.lua:1301`, `prefabs/mushtree.lua:698`, etc.). A felled tree
    keeps that tag when it becomes a stump, which adds `stump` and switches its
    `workable.action` to `ACTIONS.DIG` (`prefabs/evergreens.lua:472-481`). Marble and
    petrified trees have `tree` but their workable action is `ACTIONS.MINE`
    (`prefabs/marbletree.lua:96-98`, `prefabs/tree_rocks.lua:449-451`). So "felled a
    tree" is `target:HasTag("tree")`, no `stump` tag, `workable.action == ACTIONS.CHOP`,
    and `workable.workleft <= 0` at `working` time.
  - `oneat` → `{ food = <entity>, feeder = <entity> }`, pushed on the **eater**
    (`components/eater.lua:270`) after stats are applied and before the food is removed;
    `food.prefab` is the eaten item's id. `oneaten` → `{ eater = <entity> }` is the
    mirror image, pushed on the **food** (`components/edible.lua:210`). Vanilla
    `butterfly` has no `edible` component (`prefabs/butterfly.lua`), so it cannot be
    eaten; `butterflywings` is edible (`prefabs/butterflywings.lua:36-39`) and
    `moonbutterfly` is likewise not edible (`prefabs/moonbutterfly.lua`). An `eat`
    objective for `butterfly` therefore never completes in vanilla.
  - `healthdelta` → `{ oldpercent, newpercent, overtime, cause, afflicter, amount }`,
    pushed on the entity whose health changed by `Health:DoDelta`
    (`components/health.lua:642`). **`amount` is the requested delta, not the health
    actually gained**: `DoDelta(20)` at 148/150 pushes `amount = 20` while `SetVal` caps
    at 150. The requested amount is deliberate credit for mod objectives (overheal
    counts); use `(newpercent - oldpercent) * health.maxhealth` instead if you need the
    points that fit. `health.maxhealth` is a plain field set by `Health:SetMaxHealth`
    (`components/health.lua:503-505`); there is no `GetMaxHealth` method
    (`GetMaxWithPenalty` exists for the penalty-capped maximum). The event also fires for
    overtime healing (sleeping bags, hot springs, elixirs), so deltas can be fractional.
    **The event fires even when no health is gained**: `DoDelta` calls `SetVal`
    unconditionally and pushes afterwards (`components/health.lua:613-642`), so a heal
    applied at full health pushes `oldpercent == newpercent` with a positive `amount`
    (all overheal). `amount == 0` (`Health:SetPercent`, `components/health.lua:550-553`)
    or a negative `amount` counts nothing.
  - `sanitydelta` → `{ oldpercent, newpercent, overtime, sanitymode }`, pushed on the
    entity by `Sanity:DoDelta` (`components/sanity.lua:405`). **Unlike health there is no
    `amount` in the event**, and `DoDelta` clamps `current` between 0 and
    `max - max * penalty` (`components/sanity.lua:387`), so a gain that overflows the bar
    cannot be recovered from the percentages. To credit requested (overheal) amounts,
    observe the component itself: `modmain.lua` wraps `Sanity.DoDelta` via
    `AddComponentPostInit("sanity")` and stores the requested delta on the component as
    `_guidedmissions_last_delta` before vanilla pushes the event. Falling back to
    percentages: use the difference scaled by `sanity.max` (the field behind
    `Sanity:SetMax`, `components/sanity.lua:312`). Note `GetPercent()` is forced to 0/1 by
    induced insanity/lunacy (`components/sanity.lua:288-293`), so percent deltas are
    masked while those are active — the recorded raw delta is not.
    Be aware `Sanity:LongUpdate` calls `DoDelta(self.rate * dt, true)` every tick
    (`components/sanity.lua:609`), so positive auras/rates push continuous small
    `sanitydelta` events, including at full sanity.
  - **Threshold reads:** read the raw component fields, never `GetPercent()`:
    `health.currenthealth / health.maxhealth` and `sanity.current / sanity.max` (all
    plain numbers). `Health:IsDead()` is `currenthealth <= 0`
    (`components/health.lua:546-548`); use it to skip dead/ghost players.
    `Health:SetPercent(percent)` is `components/health.lua:550-553` and
    `Sanity:SetPercent(percent)` is `components/sanity.lua:302-306`. The debug commands
    `c_sethealth(n)` / `c_setsanity(n)` (`consolecommands.lua:388-393` / `:404-409`)
    clamp to 1, skip ghosts, and call `SetPercent`, so they are a convenient in-game
    trigger test.
  - `picksomething` → `{ object = <plant>, loot = <entity or list> }`, pushed on the
    **picker** by `Pickable:SpawnProductLoot` (`components/pickable.lua:481,505`) when
    the picker has an inventory and the pick produced loot. It does not fire on the
    `droppicked` + lootdropper branch (flowers do not use it). The plant itself gets
    `picked` → `{ picker, loot, plant }` (`components/pickable.lua:575`).
  - **Picking a flower restores sanity as part of the pick**: `onpickedfn` calls
    `picker.components.sanity:DoDelta(TUNING.SANITY_TINY)` (`prefabs/flower.lua:57`;
    `SANITY_TINY = 5`, `tuning.lua:2033`). Evil flowers add or remove that amount
    depending on the mode (`prefabs/flower_evil.lua:25-30`). **Petals do not restore
    sanity**: they are edible with `healthvalue = TUNING.HEALING_TINY` (1), `hungervalue
    = 0`, and no `sanityvalue` (`prefabs/petals.lua`), while evil petals give
    `sanityvalue = -TUNING.SANITY_TINY` (`prefabs/petals_evil.lua:61`). A "restore
    sanity by picking flowers" objective should therefore count picks, not petal eats.
  - **Mining**: boulders/rocks, salt and moon rocks, marble trees and petrified trees
    use `workable.action = ACTIONS.MINE` (`prefabs/rocks.lua`, `prefabs/marbletree.lua:
    96-98`, `prefabs/tree_rocks.lua:449-451`). The `working`/workleft test above is the
    same as for chopping.
- `playeractivated` is pushed to `TheWorld` in `prefabs/player_common.lua` (~line 826),
  after `ActivateHUD` has already run `hud:SetMainCharacter(inst)`.

## Cooking and food

- **Fire cooking pushes no player event.** `ACTIONS.COOK.fn` (`actions.lua:2013-2038`)
  removes the ingredient from the doer, calls
  `act.target.components.cooker:CookItem(ingredient, act.doer)` and hands the returned
  product back to the doer. `Cooker:CookItem` (`components/cooker.lua:25-49`) spawns the
  product via `Cookable:Cook` and returns it, or returns `nil` when `CanCook` fails;
  `Cookable:Cook` (`components/cookable.lua:19`) also pushes nothing. There is no
  `cook`/`cooked` event to listen for.
- **Which prefabs are "cookers":** campfire (`prefabs/campfire.lua:174`), firepit
  (`prefabs/firepit.lua:211`) and the lighter (`prefabs/lighter.lua:359`) add the
  `cooker` component. The crockpot adds `stewer` instead (`prefabs/cookpot.lua:309`), so
  a `cooker` hook excludes crockpot meals by construction. To observe fire cooking,
  wrap `CookItem` from `AddComponentPostInit("cooker", fn)` (`modutil.lua:566-573`;
  `fn(component)` runs after construction) and return its result unchanged — this mod
  pushes a `guidedmissions_cookedfood` event to the chef from that wrapper.
- **Crockpot cooking also emits no player event.** `ACTIONS.COOK.fn`
  (`actions.lua:2042-2053`) calls `stewer:StartCooking(act.doer)` for a target with a
  `stewer` component. `Stewer:StartCooking` (`components/stewer.lua:130-180`) computes
  `self.product` with `cooking.CalculateRecipe`, records `self.chef_id` (the starter's
  userid) and `self.ingredient_prefabs`, sets `self.targettime`, and pushes nothing.
  `Stewer:Harvest` (`components/stewer.lua:276`) spawns the finished dish and pushes
  `learncookbookrecipe` on the harvester only when `chef_id == harvester.userid` and the
  recipe has a cookbook category — not a general "dish cooked" signal. To observe it,
  wrap `StartCooking` from `AddComponentPostInit("stewer", fn)`; check `IsCooking()`
  before and after so a call that does not start a pot reports nothing. `product` here is
  a prefab id **string**, not an entity. The pot can later rewrite it to `"wetgoop"` if
  left in rain (`prefabs/cookpot.lua:225-233`), so crediting at start can over-credit a
  dish that gets ruined; `Stewer:StopCooking("fire")` spawns the product at the pot.
- **Food identification:** any item with a `components.edible` table is food, raw or
  cooked. `edible.foodtype` / `edible.secondaryfoodtype` hold `FOODTYPE` strings
  (`constants.lua:2026`). Berries are main type `VEGGIE` with secondary type `BERRY`
  (`prefabs/veggies.lua:88-108`, assigned at `:599-600`; cooked variants at `:749-750`),
  and **both `berries` and `berries_juicy` use that pair**, so
  `secondaryfoodtype == "BERRY"` catches either variety. Carrots are plain `VEGGIE`, as
  are mushrooms/corn/etc., so `foodtype == "VEGGIE"` is broad. The edible property
  setters also add `edible_<foodtype>` tags (`components/edible.lua:9-15`), but reading
  the fields avoids relying on when the tag was applied. The full `FOODTYPE` set
  (`constants.lua:2026-2047`) is `GENERIC`, `MEAT`, `VEGGIE`, `ELEMENTAL`, `GEARS`,
  `HORRIBLE`, `INSECT`, `SEEDS` (plural — not `SEED`), `BERRY`, `RAW`, `BURNT`, `NITRE`,
  `ROUGHAGE`, `WOOD`, `GOODIES`, `MONSTER`, `LUNAR_SHARDS`, `CORPSE`, `MIASMA`.
  Comparisons are exact strings.
- `Inventory:ForEachItem` (`components/inventory.lua:667-685`) visits item slots, equip
  slots, the active/cursor item and the overflow container. The overflow container
  **is** a worn body container: `GetOverflowContainer` (`:1459-1467`) returns the
  equipped `EQUIPSLOTS.BODY` item when it has an openable `container`, and a backpack
  keeps `canbeopened = true` while worn (`prefabs/backpack.lua` only toggles it on
  ignite/extinguish, lines 212-222). So `ForEachItem` **does** count a worn backpack's
  contents; it does not recurse into other carried containers.

## Farming and planting

- **Tilled farm plots are `farm_soil` entities** (`prefabs/farm_soil.lua`): the
  hoe/plow tills ground into these, and they are the only targets carrying the
  `soil` tag (the prefab adds it at `:115`). Seeds are the items with a
  `farmplantable` component.
- **Planting in tilled soil fires no player event.**
  `componentactions.lua:1235` inserts `ACTIONS.PLANTSOIL` when the held item has
  a `farmplantable` component and the target has the `soil` tag and is not
  `NOCLICK`. `ACTIONS.PLANTSOIL.fn` (`actions.lua:4727-4745`) removes the seed
  from the doer's inventory and calls `FarmPlantable:Plant(target, doer)`,
  giving the seed back if that returns false.
- **`FarmPlantable:Plant`** (`components/farmplantable.lua:7-30`) requires
  `self.plant` and a `soil` target, computes the crop prefab with
  `FunctionOrValue(self.plant, self.inst)`, removes the soil, spawns the crop,
  pushes `on_planted` on the **crop** with `{ doer, seed, in_soil = true }`, and
  pushes `itemplanted` on **TheWorld** with `{ doer, pos }`. `self.inst` is the
  seed entity and is removed on success (`:25`), so read its prefab before
  calling. There is no event on the planter.
- **`itemplanted` is not a seed-planting signal.** It is pushed by the old farm
  `grower` component (`components/grower.lua:144`) and by unrelated prefabs
  (mushroom farm, seastack, waterplant rock, winter tree stand); the component
  file itself notes "this event is pushed in other places too". Hook the
  component that performs the plant instead.
- **Seed prefabs:** the generic seed is `seeds` (`prefabs/seeds.lua:159-160`,
  `farmplantable.plant = pickfarmplant` → `farm_plant_randomseed`); crop seeds
  are `<crop>_seeds` (`prefabs/veggies.lua:514-515`, `farmplantable.plant =
  "farm_plant_<crop>"`). The same files also add a `plantable` component
  (deprecated, for crafted farm structures) and a `deployable` component.
- **Seeds are deployable only for Wormwood.** Their `deployable` has
  `restrictedtag = "plantkin"`, and `Deployable:IsDeployable`
  (`components/deployable.lua:88-90`) requires the deployer to carry that tag
  (Wormwood; `debugcommands.lua:2163`). `Deployable:Deploy` (`:132-147`) calls
  the seed's `ondeploy` callback, which spawns the crop directly instead of
  going through `FarmPlantable:Plant`, then pushes `deployitem` on the deployer
  and returns `true`. After a successful deploy the seed is already removed, so
  capture `inst.prefab` before the call. Normal characters cannot reach this
  path.
- **The old farm structures are retired.** `prefabs/farmplot.lua` only returns
  `slow_farmplot`/`fast_farmplot` (the plain `farmplot` prefab is commented out
  at `:375`) and plants through `Grower:PlantItem`
  (`components/grower.lua:110-147`), which uses the `plantable` component and
  pushes no player event either.
- **Dug bushes, grass, saplings and reeds are deployed, not planted.** The
  `dug_<plant>` items are built by `prefabs/plantables.lua`
  (`make_plantable`, prefab at `:116`); they carry a `deployable` component
  (`:96-99`, deploy mode `PLANT`) and **no `farmplantable`**, and their
  `ondeploy` (`:19-40`) spawns the plant prefab directly and calls
  `Pickable:OnTransplant`. So replanting a dug plant goes through
  `Deployable:Deploy` and never reaches `FarmPlantable:Plant`.
- **`deployedplant` is vanilla's own "this deploy was a planting" tag.**
  `Deployable:Deploy` (`components/deployable.lua:132-147`) computes
  `isplant = self.inst:HasTag("deployedplant")`, spawns through `ondeploy`,
  pushes `deployitem` on the deployer with `{ prefab = <item id> }` — note it
  reads `.prefab` off the item *after* `ondeploy` removed it, which works
  because `prefab` is a plain field — and then pushes `itemplanted` on
  **TheWorld** (not the deployer) when `isplant`. The tag is added by
  `prefabs/plantables.lua:48` (dug bushes/grass/saplings/reeds), and also by
  acorns, pinecones, ancient tree seeds, kelp and living-tree roots, and
  butterflies (releasing one plants a flower). It is therefore "planted
  something", not "planted a dug bush".
- **Consequence for this mod:** `modmain.lua` wraps `FarmPlantable:Plant` and
  `Deployable:Deploy`, pushing `guidedmissions_planted` with
  `{ item = <held item prefab id> }` to the planter. The deploy wrapper reports
  when the item has a `farmplantable` component **or** the `deployedplant` tag,
  so a `plant` objective covers seeds, dug plants and the other tagged
  plantables. The grown crop or spawned bush is never reported: matching
  filters on the held item (`carrot_seeds`, `dug_berrybush`), not the crop
  (`farm_plant_carrot`) or the bush (`berrybush`). Because `deployitem` carries
  no tag and `itemplanted` carries no prefab, the mod's component wrapper is
  what ties the item id to "was this a planting".

## Fertilizing

- **Fertilizing emits no player event.** `ACTIONS.FERTILIZE.fn`
  (`scripts/actions.lua:1812-1840`) picks a target branch in this order and
  calls that component's `Fertilize(invobject, doer)`:
  - `target.components.crop` and not ready for harvest and not withered →
    `Crop:Fertilize` (tilled farm soil);
  - `target.components.grower` and empty → `Grower:Fertilize` (retired
    `slow_farmplot`/`fast_farmplot`);
  - `target.components.pickable` and `CanBeFertilized()` →
    `Pickable:Fertilize` (**bushes, grass, reeds**), which also pushes
    `CHEVO_fertilized` on **TheWorld** (`:1823`) — a world event, not a player
    event, and only for this branch;
  - `target.components.quagmire_fertilizable` → the Quagmire branch.
  If none applied and the target is nil or the doer,
  `doer.components.fertilizable:Fertilize` runs (fertilizing yourself).
- **Only barren or withered pickables can be fertilized.**
  `Pickable:CanBeFertilized` (`components/pickable.lua:251-253`) is
  `IsBarren() or HasTag("withered")`, and `IsBarren` is `cycles_left == 0`
  (`:378-380`; the `barren` tag is added by the `cycles_left` net-var watcher at
  `:10-16`). A plant that is still producing offers no FERTILIZE action, so a
  bush cannot be fertilized immediately after planting it.
- **Cycle budgets** (`prefabs/berrybush.lua:343-357`, `prefabs/grass.lua:248-255`):
  berry bush `max_cycles = TUNING.BERRYBUSH_CYCLES (3) + math.random(2)`, juicy
  bush the same with `BERRYBUSH_JUICY_CYCLES (3)`, grass
  `GRASS_CYCLES = 20` (`tuning.lua:1777-1787`). Harvesting decrements
  `cycles_left`; at 0 the plant is barren. Winter withering makes any of them
  fertilizable regardless of cycles.
- **`Pickable:Fertilize(fertilizer, doer)`** (`components/pickable.lua:259-293`)
  resets `cycles_left = max_cycles`, extends `protected_cycles` by the
  fertilizer's `withered_cycles`, then either `Witherable:ForceRejuvenate` (when
  still withered) or `MakeEmpty`, and **always returns true** — it has no
  failure path. The plant entity survives the call.
- **The fertilizer item is consumed after, not inside, that call.** The action
  calls `invobject.components.fertilizer:OnApplied(doer, target)` only when the
  branch returned true (`actions.lua:1836-1838`); `Fertilizer:OnApplied`
  (`components/fertilizer.lua:33-49`) spends `finiteuses` or removes the stack.
  Reading `fertilizer.prefab` inside a `Fertilize` wrapper is therefore safe,
  but the item is gone by the time the action returns.
- **Consequence for this mod:** `modmain.lua` post-inits `pickable` and wraps
  `Fertilize`, pushing `guidedmissions_fertilized` with
  `{ plant = <the plant entity>, fertilizer = <fertilizer prefab id> }` to the
  doer. Only this branch is hooked, so fertilizing farm crops or old farm plots
  is deliberately not reported. Objective filters match `plant.prefab`
  (`berrybush`, `grass`, `reeds`), not the fertilizer.

## Traps

- **Checking a trap is `CHECKTRAP`, not `HARVEST`.** `ACTIONS.CHECKTRAP.fn`
  (`scripts/actions.lua:1686-1689`) calls `act.target.components.trap:Harvest(act.doer)`.
  The `trap` component is in `scripts/components/trap.lua`.
- **`Trap:Harvest(doer)` (`components/trap.lua:350`) is the only place the checker
  is known.** It hands the stored loot to `doer` and then resets/re-arms the trap
  (`Reset()` clears `lootprefabs`), so read the loot and the caught prefab *before*
  calling it.
- **The caught creature is not stored anywhere after spring.** `Trap:DoSpring`
  (`:270`) writes the loot list:
  - inventory-item targets (rabbit): `self.lootprefabs = { self.target.prefab }`
    (`:283`), so the creature id survives in loot;
  - lootdropper targets (spider, frog): `GenerateLoot()` (`:287-290`), i.e. the
    **drops**, not the creature;
  - then the target is removed.
  A trap that springs on something untrappable has `lootprefabs == nil`; checking it
  is not a catch.
- `Trap:OnSave`/`OnLoad` (`:439`/`:456`) persist `loot`, which is why a sprung trap
  still holds a catch across a save.
- **Consequence for this mod:** `modmain.lua`'s `trap` post-init wraps `Harvest`,
  captures `lootprefabs` before the call, and pushes `guidedmissions_trapchecked`
  to the checker with `{ loot = <lootprefabs> }`. Objective filters match **loot
  ids**, not the creature: rabbits store `{ "rabbit" }`, while spiders/frogs store
  their drops.

## Sleeping (tents, siesta huts, bedrolls)

- **Entering a bed emits no player event.** `ACTIONS.SLEEPIN.fn`
  (`scripts/actions.lua:2699-2710`) resolves the bed (a target tent or a held
  bedroll) and calls `bag.components.sleepingbag:DoSleep(act.doer)`.
- **`SleepingBag:DoSleep(doer)`** (`components/sleepingbag.lua:61-73`) does nothing
  unless the bed is free and the player is not already in one; otherwise it sets
  `self.sleeper` / `doer.sleepingbag` and calls
  `doer.components.sleepingbaguser:DoSleep(self.inst)` (`:66`). That call is the
  exact moment the player enters.
- **`SleepingBagUser:DoSleep(bed)`** (`components/sleepingbaguser.lua:40-51`) records
  `self.bed` and starts the sleep tick task. The component is added to players in
  `prefabs/player_common.lua:2829`, inside the server-only component block; the
  client player is `player_classified` and has no `sleepingbaguser`.
- **Consequence for this mod:** `modmain.lua`'s `sleepingbaguser` post-init wraps
  `DoSleep`, calls vanilla, then pushes `guidedmissions_slept` on the player with
  `{ bed = <the bed entity> }`. Because the bed only reaches this call after its
  checks, the event fires exactly once per entry, not on wake-up. `bed.prefab` is
  `tent`, `siestahut`, or a `bedroll_*` prefab.

## Recipe prototyping

- **`unlockrecipe` → `{ recipe = <recipe name> }`**, pushed on the player by
  `Builder:UnlockRecipe` (`components/builder.lua:463-473`). This is the signal Klei itself
  uses for the `character.prototyped` metric (`components/playermetrics.lua:7-16`).
- Sources: crafting a recipe at a crafting station for the first time
  (`components/builder.lua:1005-1080`, `Builder:BufferBuild` ~`:1140-1180`), learning from
  blueprints/teachers (`components/teacher.lua:21`, `prefabs/blueprint.lua:41`), recipe
  scanners (`components/recipescanner.lua:39`), Webber's spider teacher
  (`prefabs/spider.lua:347`) and character skill unlocks (`prefabs/wx78_common.lua:637`).
- **A data-less `unlockrecipe` also exists**: `Builder:GiveAllRecipes`
  (`components/builder.lua:136-139`) flips free-build mode and pushes it with no payload
  (reached from `c_giveallrecipes`, `consolecommands.lua:361`). Guard
  `data.recipe ~= nil` — `playermetrics.lua` does the same.
- **The event is not deduplicated.** `Builder:UnlockRecipe` pushes even when the recipe is
  already known, and `widgets/widgetutil.lua:127-143` calls it unconditionally for
  placed-structure recipes every time the player starts placement. (Actual crafting paths
  do check `KnowsRecipe` first, so items are not affected.) `Builder:UnlockRecipesForTech`
  can bulk-push every recipe matching a tech level but is only reached from
  `debugcommands.lua:576`. To count *new* recipes, keep a set of recipe ids seeded from
  `builder.recipes` (`AddRecipe` appends there, `components/builder.lua:451-456`) after
  load and credit each id once — this mod does that in the mission manager.
- **`TECH.NONE` recipes never fire it.** `Builder:KnowsRecipe` (`components/builder.lua:
  841-921`) returns true from the start for a recipe whose `level` entries are all zero,
  because `recipe.level[v] > bonusvalue` is `0 > 0` and fails. Crafting an axe/pickaxe/
  torch/campfire for the first time therefore takes the `elseif not recipe.nounlock then
  self:AddRecipe(recipe.name)` branch (`builder.lua` ~`:1075-1078`, and the same pattern in
  `_TryMakeIngredientRecipe` ~`:1035-1038`), which adds it to `builder.recipes` **without
  pushing `unlockrecipe`**. Blueprint generation also excludes `TECH.NONE`
  (`prefabs/blueprint.lua` `CanBlueprint*` require a non-zero tech level). So the event
  means "newly unlocked/prototyped recipe" (station tech or taught recipe), not "first time
  the player built this item" — use the `builditem`/`buildstructure` recipe payload for
  first crafts.
- `Builder:KnowsRecipe(recipe, ignore_tempbonus)` (`components/builder.lua:841`) accepts a
  string or recipe table, but it also returns true for recipes currently accessible through
  station/tech bonuses (`station_recipes`, tech trees), so it is not a reliable "was this
  permanently learned before?" test. Use the `builder.recipes` list for that.

## Console and chat commands

- **Slash commands do not work in the current UI.** The redux chat sidebar
  (`widgets/redux/chatsidebar.lua` ~77-84) trims the line and sends it with
  `TheNet:Say`; it never calls `UserCommands.RunTextUserCommand`. Only the legacy
  `screens/chatinputscreen.lua:169` parses a leading `/`. `AddUserCommand` is
  therefore unreachable from normal chat; do not use it for anything a player or
  developer needs to run.
- The debug console (`~`) autocompletes **global functions whose names start with
  `c_`**: `screens/consolescreen.lua` iterates `pairs(_G)` once and builds its
  prediction dictionary from `type(v) == "function"` and `k:find("c_") == 1`.
  A mod can therefore expose console commands by assigning
  `GLOBAL.c_mycommand = function(...) ... end` in `modmain.lua`. The dictionary is
  built the first time the console screen is created, so define commands at load.
- **Quoted arguments autocomplete from prefab names.**
  `screens/consolescreen.lua:271-274` adds two dictionaries to the console
  `TextEdit` (`AddWordPredictionDictionary`, `widgets/textedit.lua:652`):
  `{ words = prefab_names, delim = '"', postfix = '"', skip_pre_delim_check = true }`
  and the same with `'`. Command names use `delim = "c_"` / `"d_"` with
  `num_chars = 0` (`:296-301`). A dictionary's `delim` is an arbitrary opening
  string, `postfix` is appended when a suggestion is accepted, and
  `num_chars = 0` shows suggestions immediately.
- **`WordPredictor` is Lua, not engine-bound.** It is
  `require "util/wordpredictor"` (`widgets/wordpredictionwidget.lua:8,31`;
  `scripts/util/wordpredictor.lua`). `_find_prediction_start` scans backwards
  from the cursor and, at each position, walks `self.dictionaries` in insertion
  order, stopping at the **first** dictionary that yields a match
  (`wordpredictor.lua:28-95`). Dictionaries are a plain public list
  (`self.dictionaries = {}`, `:9`); there is no removal call, but entries can be
  inserted or reordered directly. Consequence: a dictionary appended after the
  vanilla prefab one never wins at the same delimiter position — for
  `c_setmission("green`, the `"` prefab dictionary matches first and suggests
  `green_mushroom` even if a command-scoped dictionary was also added.
- **A long `delim` breaks quoted completion everywhere, not just its own
  matches.** `_find_prediction_start` computes `text:sub(pos - (#dic.delim-1), pos)`
  and, when that slice is shorter than the delimiter (`#pos_char ~= #dic.delim`
  because `pos` is near the start of the line), it `break`s out of the whole
  dictionary loop for that position (`wordpredictor.lua:39-44`). A dictionary
  with, say, `delim = 'c_setmission("'` therefore disables prefab autocomplete
  for every short command such as `c_give("...`, where the quote is closer than
  the delimiter length to the start. Verified in-game 2026-11-12 (all console
  autocomplete stopped until the dictionary was removed). Keep mod delimiters
  short, or scope completion by swapping `prediction_widget.word_predictor`
  instead of stretching `delim`.
- **Examining dictionaries:** the list is `prediction_widget.word_predictor.dictionaries`
  on the console's `TextEdit` after `AddClassPostConstruct("screens/consolescreen", ...)`
  (`modutil.lua:161-164` wraps `_ctor`, and the edit widget is built inside it).
  `AddDictionary` appends and fills `postfix`/`GetDisplayString` defaults; order
  decides which dictionary wins at a given position.
- An in-game admin's console starts in **remote execute** mode (Ctrl toggles;
  `ConsoleScreen:ToggleRemoteExecute`). Remote input is sent with
  `TheNet:SendRemoteExecute` and evaluated on the server by
  `ExecuteConsoleCommand` (`mainfunctions.lua:2166`), which temporarily sets
  `ThePlayer` to the caller's server-side entity. A `c_` function can therefore
  reach server components directly when `TheNet:GetIsServer()` is true.
- Local evaluate runs in the client VM, where `ThePlayer` only has replicas.
  Forward to the server with `AddModRPCHandler` + `SendModRPCToServer`
  (`networkclientrpc.lua`); the handler receives `(player_entity, data)` and must
  re-check admin with `TheNet:GetClientTableForUser(player.userid).admin`, because
  any client can send an RPC.

## World state (server)

- `TheWorld.state` is assigned as `inst.components.worldstate.data` in
  `prefabs/world.lua` (~line 533).
- It contains `cycles`, `time`, `phase`, `season`, `isday`, `isnight`, weather flags,
  etc. — **there is no `day` field**. `TheWorld.state.day` is `nil`.
- The day number shown by the HUD clock is `TheWorld.state.cycles + 1`
  (`prefabs/world.lua:321`, `widgets/uiclock.lua`); `cycles` starts at 0.
- `TheWorld.components.worldstate:GetWorldAge()` returns `1 + cycles + time`, a float
  where `time` is the fraction of the current day.
- Use `cycles + 1` for "reach day N" objectives.

## Netvars

- Constructors: `net_string(guid, name)` or `net_string(guid, name, dirty_event_name)`;
  the dirty-event argument is optional (game examples:
  `components/named_replica.lua`, `components/lavaarenaeventstate.lua`).
- Constructors are **engine-bound** — there is no `function net_string` in Lua, so
  confirm the signature from usage, not by searching for its definition.
- **Declarations must be identical on the server and on every client**, for every entity.
  A mismatch fails entity deserialization. Never conditionally skip the attach step —
  not even when the local player has the tracker disabled.
- The dirty event fires *before* the Lua update runs. In this mod all five tracker
  strings (`title`, `subtext`, `rows`, `state`, `hint`) share one dirty event so the
  client re-renders once per state change.
- `scripts/netvars.lua`'s header documents the types and states that when a **mod** uses
  netvars, server and every client must have the same mod active. `net_string` is listed
  as "variable length string" with **no Lua-visible maximum**; keep payloads small
  (a few hundred bytes) rather than relying on a cap. `net_bytearray`/`net_ushortarray`
  are capped at 31 elements and described as expensive — prefer one packed string.

## Text and HUD

- `Text(font, size, text, colour)` — font first. `DEFAULTFONT = "opensans"`
  (`scripts/fonts.lua`). `Text:SetHAlign` / `Text:SetVAlign` are in
  `scripts/widgets/text.lua`.
- **`Text:SetPosition` is the CENTER of the text's region, and `SetHAlign` /
  `SetVAlign` align the string *inside* that region** — not an offset of the region's
  edge. With no `SetRegionSize`, the region auto-sizes to the string, so alignment has
  no visible effect and a left-aligned label still grows both ways from its position.
  To left-align at a fixed edge, set an explicit region and position its center:
  `text:SetRegionSize(w, h); text:SetHAlign(ANCHOR_LEFT); text:SetPosition(x + w/2, y)`.
  Vanilla does exactly this: `widgets/redux/achievementspanel.lua:113-122` (a row-wide
  region centred on the row origin, text aligned left/right within it) and
  `widgets/redux/characterbio.lua:77-89` (region equals text width, so they position at
  `left + 0.5 * width`). Getting this wrong is how a HUD label ends up half off-screen.
- **To measure rendered text, reset the region first.** `GetRegionSize()` returns
  whatever region was set with `SetRegionSize`, not the text extent — so measure the way
  `Text:SetAutoSizingString` does (`widgets/text.lua:288-300`): `SetString(s)`,
  `ResetRegionSize()`, then `GetRegionSize()`. The tracker measures the card title this
  way so the hint button can hang immediately after the text instead of in a fixed slot.
  **`GetRegionSize()` does not reliably report the height of a string containing
  `\n`** (observed in-game 2026-11-12: a wrapped 3-line hint still measured as one line,
  so a backing sized from it was too short). When you control the wrapping with
  `SetMultilineTruncatedString`, use its **return value (the line count)** times a
  one-line height instead.
- **Hover text is a `Widget` method, not a separate widget.** `Widget:SetHoverText(text,
  params)` (`widgets/widget.lua:708`) lazily builds a `hovertext_root` with a
  `NEWFONT_OUTLINE` text at 22 (scaled 1.1×) over an `images/frontend.xml` /
  `scribble_black.tex` backing tinted to alpha 0.8, and wraps the widget's existing
  `OnGainFocus`/`OnLoseFocus` — so an `ImageButton` keeps its focus texture and gets the
  tooltip. It shows at the widget's world position plus `offset_x` (default 0) and
  `offset_y` (default **+26**, i.e. above the widget; use a negative value to hang it
  below, as this mod's "?" button does).
  - `params` also accepts `font`, `font_size`, `colour`, `region_w`, `region_h`,
    `wordwrap`, `bg = false`, and `attach_to_parent`. With `attach_to_parent`, the root
    is added as a child of that widget, positioned in its local space and
    `MoveToFront`ed — the HUD-scale-safe form. The crafting menu uses
    `{ offset_y = 30, attach_to_parent = self }` (`widgets/redux/craftingmenu_widget.lua:668,749`).
  - `SetHoverText` on a widget that already has hover text **only updates the string and
    colour** (`widget.lua:800-812`); the font, region, wordwrap and offsets are fixed at
    creation, and the focus closure captures the params table by reference, so mutating
    that table later still moves the tooltip. `SetHoverText("")` does nothing — use
    `ClearHoverText()` (`widget.lua:819`) to remove it.
  - **Word-wrapped tooltips need explicit backing sizing.** Passing `region_w` +
    `wordwrap` sizes the dark backing from `GetRegionSize()`, which returns the *region*
    once one is set, so the backing becomes `region_w * 1.5` wide whatever the text.
    To keep it snug, pre-wrap the string with
    `Text:SetMultilineTruncatedString(str, maxlines, maxwidth, nil, true)`, which inserts
    newlines and **returns the line count**, then size the backing as
    `width × (line_height × lines)`. Measure the one-line height before wrapping (a
    50px BMFont has `lineHeight = 50`, so at size *s* one line is ≈ *s* px). Do **not**
    take the height from `GetRegionSize()` after wrapping — it does not account for
    embedded newlines (see the measurement bullet above). This mod does this in
    `guidedmissiontracker.lua:SetHint`.
  - **HUD widgets do receive hover focus.** `widgets/controls.lua:128` adds
    `PlayerDeathNotification`, whose close button uses `SetHoverText`
    (`widgets/playerdeathnotification.lua:37`), and the crafting menu lives under the
    same `controls` widget (`controls.lua:16`). Controller input cannot focus HUD
    widgets, so hover is **mouse-only**.
- **The question-mark emblem** is `question.tex` / `question_over.tex` in
  `images/skilltree.xml` (44×44, hover rim included), used as an `ImageButton` in
  `widgets/redux/skilltreebuilder.lua:29-30,719`. The atlas is preloaded by the global
  prefab (`prefabs/global.lua:490`), so no `Assets` entry is needed.
- **The status badges live in the top-right, under `controls.sidepanel`.** In this
  build `widgets/controls.lua:133-135` creates
  `sidepanel = topright_root:AddChild(Widget("sidepanel"))` at `(-80, -60)`, and the
  non-split path adds `controls.status = sidepanel:AddChild(StatusDisplays(owner))` at
  `(0, -110)` (`:211-212`) and `controls.clock = sidepanel:AddChild(UIClock())`.
  `StatusDisplays` (`widgets/statusdisplays.lua:288-336`) arranges its badges on the
  widget's own origin: columns `-80, -40, 0, +40` (boat meter, hunger, sanity, health) at
  y `+20`/`-40`, so the cluster's left edge is the hunger badge. Combined Status
  (`mods/workshop-1896968971/modmain.lua:338-351`) moves `sidepanel` to `(-100, -70)` and
  rescales `topright_root` by `HUDScale * HUDSCALEFACTOR`, which is why a mod HUD must
  not assume vanilla offsets.
- **A widget cannot report its pixel size, but it can report positions.** `Widget`
  exposes `GetWorldPosition()` (screen-space, `widgets/widget.lua:336-338`),
  `GetPosition()` (parent space, `:340`) and `GetChildren()` (`:262`) — but no
  `GetSize`/`GetBoundingBox` (only `Panel`/`Image` have sizes).
  To hug a HUD element, take the extreme world position of its children and back off by
  half the element's art width: `guidedmissiontracker.lua:MeasureRightMargin` does this
  for the status badges so the card sits left of them whatever size they are.
- **`Widget:GetWorldScale()` is broken in this build — use `Widget:GetScale()`.**
  Observed in-game 2026-11-13: `GetWorldScale` (`widgets/widget.lua:348-350`) calls
  `self.inst.UITransform:GetWorldScale()`, but the engine UITransform has no such method,
  so it raises `attempt to call method 'GetWorldScale' (a nil value)` at `widget.lua:349`.
  No vanilla Lua calls `GetWorldScale()` (grep of all game scripts: zero call sites) —
  the implemented helper is `Widget:GetScale()` (`widget.lua:547-555`), which multiplies
  the widget's own `UITransform:GetScale()` by its parent's recursively, i.e. the total
  HUD scale. `GetLooseScale()` (`:557-559`) is the local-only scale. Use
  `parent:GetScale().x` to convert a screen-space delta into a dock-root local delta.
- **Dock HUD widgets to the vanilla scaling roots, not `HUD.root`.** `Controls`
  (`widgets/controls.lua:496-545`) creates `top_root`, `topleft_root`, `bottom_root`,
  `topright_root`, etc., each as a zero-size widget with `SetHAnchor` + `SetVAnchor`,
  `SetScaleMode(SCALEMODE_PROPORTIONAL)` and `SetMaxPropUpscale(MAX_HUD_SCALE)`, then
  adds a `*_scale_root` child that `Controls:SetHUDSize` scales (`:545-562`). Vanilla
  toasts and team bars are added to `controls.topleft_root` (`:111-153`); the clock and
  the status badges are in `topright_root` via `controls.sidepanel` (see above). A mod
  HUD card should follow the same pattern: add it under the root it belongs to
  (available once `SetMainCharacter` has run, i.e. by `playeractivated`) and, if it sets
  its own anchors, set the matching scale mode and max upscale. Local coordinates in a
  left-anchored root start at the screen's top-left; in a right-anchored root at the
  screen's top-right, with negative x going left and negative y downward. This mod's
  card docks to `controls.topright_root` so it lives beside the status badges rather
  than under the insight button and gift toasts.
  **Do not give the child its own `SCALEMODE_PROPORTIONAL`:** the root is already
  scaled, so a scaled child compounds it. Observed in-game (2026-10-31): a card parented
  to `controls.topleft_root` that also set `SCALEMODE_PROPORTIONAL` +
  `SetMaxPropUpscale(MAX_HUD_SCALE)` rendered 1.25× too large. Add a plain child and let
  the root scale it.
- **Crafting menu frame geometry** (needed to line a mod panel up with it). The menu HUD
  is added to `controls.left_root`, which is anchored left/middle
  (`widgets/controls.lua:302,532-535`), and `widgets/redux/craftingmenu_hud.lua:23-36`
  opens it by moving its `ui_root` to `x = 530` (not split screen) with the
  `CraftingMenuWidget` centred at `x = -255` inside that. `MakeFrame(500, height)`
  (`widgets/redux/craftingmenu_widget.lua:553-583`) then draws:
  fill `backing.tex` scaled to `width + 10` (so it spans `x = 20 .. 530`),
  left side `side.tex` at `-width/2 - 8` scaled to `|-26|` (centre `x = 17`, i.e. `4..30`,
  mirrored for the left), right side mirrored at `+width/2 + 8`, and `top.tex` /
  `bottom.tex` banners `534` wide. So when open, the crafting menu's visible wooden frame
  starts ~8 px from the screen edge and its dark fill at 20 px. `side.tex` is drawn at
  its natural aspect in our card but stretched in vanilla; the 26 px width either way
  leaves the visible plank ~4 px inside the image's left edge (transparent margin).
  Note `left_root` is scaled by `TheFrontEnd:GetCraftingMenuScale()` while the other
  roots use `GetHUDScale()` (`controls.lua:556-591`), so the two can differ by a few px
  at different user settings.
- `Image(atlas, tex)`; `Image:SetTint(r, g, b, a)` is in `scripts/widgets/image.lua`
  (~line 142). `Image("images/global.xml", "square.tex")` is valid — `global.xml`
  lives inside `data/databundles/images.zip`.
- `Widget:AddChild`, `SetPosition`, `SetHAnchor`, `SetVAnchor` are in
  `scripts/widgets/widget.lua`. `AddChild` returns the child.
- `player.HUD` is set as `maincharacter.HUD = self` in `PlayerHud:SetMainCharacter`
  (`scripts/screens/playerhud.lua`, ~line 928), called from `ActivateHUD` in
  `scripts/prefabs/player_common.lua` before `playeractivated` is pushed. Still
  null-check `player.HUD` and `player.HUD.root`.
- `TheNet:GetIsServer()` and `TheNet:IsDedicated()` are valid; `IsDedicated()` is the
  standard guard for client-only hooks (dedicated servers have no local player).

## Fonts

Verified against build 761239 (`version.txt`). Every constant in `scripts/fonts.lua` is a
plain **global** (no `local`), and `main.lua:243` does `require("fonts")` during boot, so
bare `TITLEFONT` / `UIFONT` / `BODYTEXTFONT` resolve in any `require()`d mod module and in
widget code. In `modmain.lua` (sandbox env) use `GLOBAL.TITLEFONT`.

| Constant | Alias string | Face | Typical use |
|---|---|---|---|
| `DEFAULTFONT` | `opensans` | Open Sans | plain sans fallback |
| `TITLEFONT` | `bp100` | Belisa Plumilla Manual (100px pack) | big menu titles |
| `UIFONT` | `bp50` | Belisa Plumilla Manual (50px pack) | crafting **item names**, HUD hints |
| `BUTTONFONT` | `buttonfont` | Belisa Plumilla Manual | legacy dialog titles |
| `BODYTEXTFONT` | `stint-ucr` | Stint Ultra Condensed | crafting descriptions, HUD clock, badges |
| `NUMBERFONT` / `SMALLNUMBERFONT` | `stint-ucr` / `stint-small` | Stint Ultra Condensed | counters |
| `CHATFONT` | `bellefair` | Bellefair (serif) | Redux dialog body |
| `HEADERFONT` | `hammerhead` | Hammerhead | Redux window headers |
| `NEWFONT_OUTLINE` | `spirequal_outline` | spirequal, **outline baked in** | tooltips/hover text |
| `TALKINGFONT` | `talkingfont` | Belisa Plumilla Manual | character speech |

- **The outline is baked into the BMFont atlas RGB, not its alpha.** A glyph is a white
  face plus a black outline, all at alpha 255 (the `B` in `belisaplumilla50` is 152 white
  and 724 black pixels). The engine multiplies the glyph by the `Text` colour, which
  leaves the black outline black. Anything that re-renders these atlases —
  `tests/preview/render.py` does — must **tint** the RGB rather than repaint from the
  alpha channel; repainting from alpha colours the outline too and every glyph looks fat
  and outline-less (fixed 2026-11-12).
- `UIFONT` is registered with `adjustadvance = -2` (`scripts/fonts.lua:76`), so the
  engine's rendered text is slightly tighter than the raw BMFont advances. Runtime
  measurements (`GetRegionSize`) include it; the offline preview's estimate does not.

- **Crafting menu typography** is the model for a HUD panel: recipe name is
  `Text(UIFONT, 30)` (`widgets/redux/craftingmenu_details.lua:342`) and the description
  below it is `BODYTEXTFONT` at 25 (`:361`). The HUD clock is `BODYTEXTFONT` 33
  (`widgets/uiclock.lua:120`). Belisa for names, Stint for supporting text.
- **There is no outline/shadow API on `Text`.** `SetShadowColor`, `SetOffset`,
  `SetOutline`, `SetStroke*` do not exist in `widgets/text.lua`, anywhere else in the
  scripts, or in the engine binaries. Outlines are **baked into specific font packages**
  (`NEWFONT_OUTLINE`, `CHATFONT_OUTLINE`, `FALLBACK_FONT*_OUTLINE`) — none of them Belisa.
  A drop shadow is done by adding a second offset `Text` (`widgets/button.lua:337-360`;
  manual pattern `screens/multiplayermainscreen.lua:244-251`). Otherwise put dark backing
  behind light text.
- **A mod can ship a font**, but it is not needed for vanilla fonts: declare
  `Asset("FONT", "fonts/x.zip")` and call `TheSim:LoadFont(path, alias, disable_color)`
  (the same call `mainfunctions.lua:1328-1331` uses for every base font). There is **no**
  `AddFont`/`AddModFont` API. A font package is a zip containing `font.fnt` + `font.tex`.

## Item icons and UI atlases

- **Icon convention: the texture name is `prefab_id .. ".tex"`.** `GetInventoryItemAtlas
  (imagename, no_fallback)` (`scripts/simutil.lua:663-692`) is a plain global (required by
  `main.lua:215`, long before mods load) and probes `images/inventoryimages1..4.xml` with
  `TheSim:AtlasContains`. It needs **no entity**, so a client can resolve a built-in
  prefab's icon from its id alone.
- **`GetInventoryItemAtlas` must be called with `no_fallback = true` to test whether an
  icon exists.** The last clause of `GetInventoryItemAtlas_Internal`
  (`simutil.lua:683-685`) is
  `or (not no_fallback or TheSim:AtlasContains(images4, imagename)) and images4`, so the
  default call **always returns `images/inventoryimages4.xml` even for a frame that does
  not exist** (yielding a blank/garbage quad, not nil). Use:

  ```lua
  local atlas = GetInventoryItemAtlas(prefab .. ".tex", true)
  if atlas ~= nil then image = Image(atlas, prefab .. ".tex") end
  ```
- Verified 2026-10-31 (build 761239): all of `log` (#2), `flint` (#2), `firepit` (#2),
  `goldnugget` (#2), `twigs` (#3), `torch` (#3), `spider` (#3), `researchlab` (#3) resolve
  with `<prefab>.tex` and no rename. Also verified from the atlas XML: `rocks.tex`,
  `petals.tex` and `healingsalve.tex` exist (icons for mine and pick rows, and a heal
  override), while
  `flower.tex` does not — flowers are world plants, not inventory items. `hound.tex`
  exists **only** in `images/scrapbook_icons1.xml`, so it does **not** resolve through
  this helper. `researchlab` has no `prefabs/researchlab.lua` — the id is created in
  `prefabs/scienceprototyper.lua:299` — and follows the same default.
- **Scrapbook art** (verified 2026-11-08, not used by the tracker):
  `GetScrapbookIconAtlas(imagename)` probes `images/scrapbook_icons1..3.xml` with
  `TheSim:AtlasContains` (`simutil.lua:749-771`), and all three atlases are preloaded
  unconditionally (`prefabs/global.lua:300-305`). It returns the atlas containing the
  frame, else nil (no fallback-atlas trap). `flower.tex` (124x124) is there, along with
  `flower_evil`, `berrybush`, `berrybush2`, `berrybush_juicy`, `grass` (icons1),
  `sapling`/`reeds` (icons2) and `tumbleweed` (icons3). These are **framed photographs**:
  the beige backing is baked into the texture, so a row using one reads as a photo tile
  rather than a cut-out item icon. The mod deliberately does not fall back to them.
- **World-entity art in a HUD widget: `UIAnim`** (`widgets/uianim.lua`) wraps an
  `AnimState`. The world flower is `anim/flowers.zip`, bank/build `"flowers"`,
  animations `f1`..`f10` plus `rose` (`prefabs/flower.lua:3,145-147`). A HUD widget must
  declare the vanilla anim itself — `Assets = { Asset("ANIM", "anim/flowers.zip") }` in
  modmain — because a widget does not inherit a prefab's asset list. Relative asset
  paths are resolved by searching every asset path, game data included
  (`mods.lua` registers mod assets with `force_path_search = true`, and
  `resolvefilepath` walks `package.assetpath`, `scripts/util.lua:587-620`), so a vanilla
  anim path works from a mod's `Assets`. Then
  `GetAnimState():SetBank/SetBuild/PlayAnimation`.
  **A UIAnim's visual box is anchored at its top-left at the widget position and
  extends right and down** — the art is *not* centred on the widget origin. Verified
  from `screens/redux/scrapbookscreen.lua:1687-1704`, which centres entity portraits in
  a photo: it reads `x1,y1,x2,y2 = animstate:GetVisualBB()` (raw, unscaled) plus
  `animal:GetBoundingBoxSize()` and positions with
  `posx = W/2 - x2*SCALE`, `posy = y2*SCALE - H/2`. To centre anim art on a slot at
  (x, y): read the raw box before scaling, pick `S = slot / max(width, height)`, then
  `SetPosition(x - ((x1+x2)/2)*S, y + ((y1+y2)/2)*S)`. Getting the vertical sign wrong
  puts the art a full visual height off; that happened here first because the world
  flower's art is authored around the entity's feet and it was assumed the widget
  anchored the art's base.
  The offline preview cannot draw anims (`render.py` decodes KTEX atlases and BMFonts
  only), so anim icons are laid out but blank in `tests/preview/out`.
- **HUD status-badge art**: `images/global_redux.xml` (`prefabs/global.lua:456`) contains
  `status_sanity.tex`, `status_sanity_bad.tex`, `status_health.tex`,
  `status_health_bad.tex`, `status_hunger.tex` and `status_hunger_bad.tex` — the status
  badge glyphs, drawn on one 2048 atlas in the same UV grid (each element spans 0.062 of
  the atlas, i.e. 128x128, with a soft dark halo transparent outside it). Verified
  2026-11-12 from `images/global_redux.xml` inside `data/databundles/images.zip`. The
  tracker maps the icon ids `brain` → `status_sanity.tex` and `heart` →
  `status_health.tex` via a small override table; they are the default icons for
  `sanity` and `heal` rows. Neither id is an inventory item.
  `images/scrapbook_icons1.xml` also has `icon_sanity.tex` (124x124 brain in an orange
  badge), unused by the tracker.
- Icons for non-item rows (e.g. a "survive until day N" row) have no item texture. Vanilla
  candidates, all in atlases declared unconditionally in `prefabs/global.lua`:
  `images/customisation.xml` → `day.tex` (127x127, a "DAY" wax-seal card; atlas declared at
  `global.lua:511`), or the HUD clock pieces `images/hud.xml` → `clock_NIGHT.tex` +
  `clock_rim.tex` (215x215 each; `global.lua:485`). Neither is in `inventoryimages1-4`, so
  pass the atlas explicitly: `Image("images/customisation.xml", "day.tex")`.
  `images/statusicons.xml` does not exist in this build.
- The four `inventoryimages` atlases are loaded unconditionally
  (`prefabs/global.lua:476-483`). `images/inventoryimages.xml` is legacy-for-mods and is
  **not** probed by `GetInventoryItemAtlas`.
- There is no `GetInventoryItemImage` / `GetItemImage`. Source icon art is **64x64**.
  The crafting menu draws icons at `item_size = 94` with `SetScale(0.475)` ≈ 45px
  (`widgets/redux/craftingmenu_widget.lua:937,943,1093`); inventory slots draw 64px art at
  ×1.5 (`widgets/invslot.lua:466`).
- Caveat: a prefab whose icon name differs from its id (skins, `ChangeImageName`) can only
  be resolved from a live entity: `replica.inventoryitem:GetImage()` / `:GetAtlas()`
  (`components/inventoryitem_replica.lua:157,170`). Helpers that handle this:
  `RecipeTile.sSetImageFromRecipe` (`widgets/recipetile.lua:26,114`),
  `ItemTile.sSetImageFromItem` (`widgets/itemtile.lua:16,385`).
- **The crafting menu's wooden frame is `images/crafting_menu.xml`**, always loaded
  (`prefabs/global.lua:307-312`). It is assembled from five plain `Image`s — no
  nine-slice, no corner art (`widgets/redux/craftingmenu_widget.lua:553-605`):
  `backing.tex` (63x63 fill, tinted to 0.5 alpha), `side.tex` (44x1023, mirrored on both
  edges), `top.tex`/`bottom.tex` (1023x73, drawn 534x38), `horizontal_bar.tex`
  (1023x30) as dividers. Authored panel width is ~500.
- The thin divider under a recipe name in the crafting details is
  `images/ui.xml` **`line_horizontal_white.tex`**, tinted `BROWN`
  (`{97/255,73/255,46/255,1}`, `constants.lua:2323`), 4 px tall and panel-wide
  (`widgets/redux/craftingmenu_details.lua:348-354`). It is cleaner than squashing the
  ornate `horizontal_bar.tex` into a few pixels.
- `images/ui.xml` has `checkmark.tex` (256x256); vanilla shows/hides it over a tile
  (`widgets/templates.lua:1292-1295`). **`slot_fg_prototype.tex`,
  `pinslot_fg_prototype.tex` and `craft_slot_prototype.tex` are hammer badges, not
  checkmarks.** There is no `images/statusicons.xml`.
- Decoded 2026-10-31: **`ui.xml checkmark.tex` is dark green** (average opaque RGB
  26,35,0), so `SetTint(HIGHLIGHT_GOLD)` cannot make it gold. Drawn **untinted** at
  24x24 it reads clearly on the dark wood, which is what this mod does. Gold alternatives
  if ever needed: `global_redux.xml` `star_checked.tex` (gold star, 31x31 frame) or
  `checkbox_normal_check.tex` (gold-framed checkbox), both in an always-loaded atlas
  (`prefabs/global.lua:456-457`).
- Verified against build 761239 (`images/crafting_menu.xml`): the frame also contains
  `scrollbar_arrow_up.tex`, `scrollbar_arrow_down.tex` and their `_hl` focus variants,
  each a 63x63 quad (UV span 0.0308 of the atlas). `checkmark.tex` is likewise present
  in `images/ui.xml`. Both atlases are loaded unconditionally
  (`prefabs/global.lua:307-312`).
- **Texture contents, decoded from `crafting_menu.tex` (KTEX = 128-byte header + DXT5
  mips, 2048x2048):**
  - `backing.tex` is a **solid black** 63x63 blackout texture (decoded average RGB
    0,0,0). It is the crafting menu's dimming fill, not wood. Using it as a visible
    panel background gives a flat black slab.
  - `skins_backing.tex` (219x109) is the **olive-brown speckled panel** used behind the
    skin spinner (`widgets/redux/craftingmenu_skinselector.lua:52`); it is the wooden
    fill to use when a panel needs an actual wood background.
  - `side.tex` is 44x1023 but its art only occupies **columns ~7-30**; the rest is
    transparent. A 26 px-wide `Image` therefore shows a ~13 px plank, and the
    transparent margin means geometry placement alone does not align the visible art.
    Mirrors the crafting menu: mirror the left copy (negative x scale) and inset the
    centres so the visible planks are flush with the panel edges.
  - `top.tex` and `bottom.tex` are 1023x73 ornate banner strips (drawn 534x38 by
    `MakeFrame`), and `page_bg.tex` (127x69) is a wood plank with a shaped right edge —
    useful as a tab, not as a full fill.
- `UICOLOURS` entries are `RGB()` tables of four 0-1 floats
  (`constants.lua:2326`, `RGB` at `:1662` returns `{r/255, g/255, b/255, 1}`), so they
  can be passed straight to `Text(font, size, text, colour)` and
  `Image:SetTint(unpack(UICOLOURS.X))`. Entries include `HIGHLIGHT_GOLD`,
  `GOLD_UNIMPORTANT`, `IVORY`, `IVORY_70` and `RED` (`RGB(207, 61, 61, 1)`,
  `constants.lua:2344`). `Text:SetColour` accepts either the table or RGBA numbers
  (`widgets/text.lua:56-59`), so a state-driven tint is
  `title:SetColour(UICOLOURS.RED)`.
- Resizable frames do exist if the crafting frame is too rigid: `NineSlice`
  (`widgets/nineslice.lua:52`, ten texture names, `SetSize`) and engine `Panel`
  (`widgets/panel.lua:10`, one texture + pixel borders). The engine one is the cleaner
  option for a one-texture trim: `local p = Panel(atlas, tex)` then
  `p:SetNineSliceCoords(minx, miny, maxx, maxy)` (pixel coords of the **inner** rect,
  measured from the texture's top-left — `feedbackscreen.lua:99-101` uses
  `SetNineSliceCoords(36, 20, 620, 63)` + `SetNineSliceBorderScale(0.5)`), then
  `p:SetSize(w, h)` (outer sizing). Corners keep their pixel size, edges stretch.
  `wrap(require("widgets/panel"))` — the module returns the class.
- **Slim trim candidate for a HUD card**: `images/crafting_menu.xml` `pinslot_bg.tex`
  (128x128, the wooden frame drawn around a pinned/craftable recipe), inner rect about
  `14, 14, 114, 114`; used as a nine-slice it gives a thin wooden edge at any size. Its
  interior is a light tan weave, so it needs a dark fill inset behind the text. Other
  trims decoded for comparison: `slot_bg.tex` (plain tan slot), `filterslot_bg.tex`
  (68x68 rounded tab), `page_bg.tex` (wood tab with a shaped edge), `images/9slice.xml`
  `roundbox.tex` (grey rounded box, `Panel`'s default 30,30,70,70), and the front-end
  `images/fepanels.xml` `wideframe.tex` / `tallframe.tex` (black ornate line frames).
- **The inventory bar's frame** is a single stretchy panel, not assembled art.
  `widgets/inventorybar.lua:76-77` adds `images/hud.xml` `inventory_bg.tex` (1352x250,
  dark leather interior with a ~26 px wooden rim and rounded corners) plus
  `inventory_bg_cover.tex`, and `:359-362` resizes it with
  `self.bg:Flow(total_w + 60, 256, true)` — the comment there says *"Flow is a 3-slice
  function"*. `Image:Flow` is an **engine** method (no Lua definition anywhere in
  `scripts/`), used for this one texture only, so its cap widths are not verifiable
  from scripts. Pixels: `inventory_bg.tex` is uniform between column ~26 and ~1326, so
  the caps are narrow and it stretches horizontally well; its height is authored at 250
  and `Flow`'s second argument rescales the whole panel vertically.
- **The inventory panel is only three-sided: top + left + right, open at the
  bottom** (verified by decoding: `inventory_corner.tex` is the left cap with the rail
  along its top and left edges, `inventory_filler.tex` has only a top rail, and both run
  opaque leather to their last row with no bottom border). It is drawn hanging off the
  bottom of the screen, so its open edge is hidden by the screen edge. Both pieces have
  transparent margins (~2 px at the top, ~10 px on the outer side), and the rail band
  from the texture edge inward is: 2 px transparent, ~9 px dark, ~11 px wood, ~4 px
  shadow, then leather — so the rail is ~26 px thick and the visible side rim ~20 px
  wide. Drawn at the panel's authored 256 px height (scaling it to the card height squashes the carved corners and
  thins the rail), clips it with `SetScissor`, and caps the open edge with a second,
  vertically mirrored copy (`SetScale(1,-1,1)`) clipped to the rail band only.
  **That flipped copy must be clipped to the rail band, not drawn over the whole card:**
  its leather interior is opaque, so two full-size copies simply hide each other's rail
  — whichever is drawn last wins.
  The panel is assembled by hand (one `inventory_filler.tex` stretched across the width,
  the two caps drawn over its ends) rather than with `ThreeSlice`, because `ThreeSlice`
  tiles the middle and **the filler's wooden rail carries a left-to-right gradient, so
  every tile seam shows up as a vertical line in the rail**. The leather interior is
  uniform, which is why the seams only appear in the rail band.
  Exact edge measurements from the decoded cap (all in texture px): leather interior
  `x <= 37`, inner shadow `38..42`, wood rim `43..50`, **opaque black `51..56`,
  transparent `57..63`**; down the top edge it is 2 px transparent then `~9` px black
  before the wood at row 11. The carved corner ornament sits *inside* the rim, from
  row ~8 inward. The black outline is baked into the texture and is what the carved
  corners sit against — cropping into it shortens the ornaments, so draw the panel
  exactly as authored (push out only the one fully transparent row). The transparent
  side margin then sits inside the card, where the filler drawn behind it fills it
  with leather.
- The matching 3-slice pieces exist as separate atlas regions, so the same panel can be
  drawn in plain Lua without the engine method: `inventory_corner.tex` (64x256, left cap
  with the top and bottom rim) and `inventory_filler.tex` (64x256, repeating middle) are
  in `images/hud.xml` and **referenced by no script** — they are what `Image:Flow` uses
  internally. `ThreeSlice` (`widgets/threeslice.lua`, `return ThreeSlice` at the end, so
  `require "widgets/threeslice"` works) does exactly this: start cap at native width,
  end cap mirrored, filler tiles scaled to the remaining span, and
  `Flow(width, height, true)` scales the root to the requested height. This is the
  vanilla-assembled route (`widgets/spinner.lua:87`, `widgets/votedialog.lua:43`).
- Archive split: most `images/*.xml` are in `images.zip`; for `fepanels`, `fepanel_fills`,
  `options_bg`, `globalpanels2` the `.xml` is in the zip but the `.tex` is loose in
  `data/images/`.
- Colour tables worth reusing (`scripts/constants.lua`): bare globals `BROWN`
  `{97,73,46}` (`:2321`), `GOLD`, `BLACK`, `DARKGREY`; and `UICOLOURS` (`:2326`) with
  `HIGHLIGHT_GOLD`, `GOLD_FOCUS`, `BROWN_MEDIUM`, `BROWN_DARK`, `IVORY`, `IVORY_70`,
  `RED` (`RGB(207,61,61,1)`, `:2344`).
  The HUD signals "unavailable" with a light red (`widgets/ingredientui.lua:55`) and
  otherwise uses texture swaps/alpha rather than colour; **green is not used for
  positive state**.

## UI sounds

- `TheFrontEnd:GetSound():PlaySound(event, name, volume)` — `scripts/frontend.lua:564-566`,
  emitter created at `:213`. `TheFrontEnd` is a client-only global (`main.lua:326`,
  `mainfunctions.lua:1442`) and is the normal way HUD widgets play sounds
  (`widgets/button.lua:68`, `screens/playerhud.lua:1067`). Pass `nil` for `name` on
  one-shots; the third argument is a volume multiplier
  (`widgets/redux/craftingmenu_pinslot.lua:186`).
- `TheFocalPoint.SoundEmitter:PlaySound(...)` is the positional alternative
  (`prefabs/world.lua:548`, used at `widgets/widgetutil.lua:147`).
- HUD sounds sit under the `set_sfx` mixer bus (`scripts/mixes.lua:10`), so they follow
  the player's FX volume slider (`playerprofile.lua:1720-1723`).
- Event strings confirmed present in `data/sound/dontstarve.fev`: `dontstarve/HUD/click_move`,
  `click_mouseover`, `click_negative`, `click_object`, `craft_open`, `craft_close`,
  `craft_up`, `craft_down`, `research_unlock`, `research_available`, `recipe_ready`,
  `collect_resource`, `collect_newitem`, `get_gold`, `feed`, `XP_bar_fill_unlock`,
  `poi_register`; plus `wilson_rework/ui/skill_mastered`, `shadow_skill`, `lunar_skill`,
  `respec` in `wilson_rework.fev`. (`scripts/haptics.lua:601-624` is Klei's own
  `category="UI"` list.) **There is no quest/achievement/"complete" event** — pick an
  existing sting. A `.fev` hit proves the name is in the project string table, not that
  the path resolves at runtime; every name above also has a live call site in vanilla Lua.

## Widget animation, show/hide and clicks

- **Tweening is built in.** `Widget:MoveTo(from, to, seconds, fn)` (`widgets/widget.lua:179-184`),
  plus `ScaleTo` (`:166`), `RotateTo` (`:192`), `TintTo` (`:205`) and `CancelMoveTo` (`:173`).
  Implemented by the `uianim` component with fixed `outCubic` easing
  (`components/uianim.lua:148-233`). Starting a new `MoveTo` fires the previous pending
  callback immediately (`uianim.lua:109-111`), and animations keep running while the
  server is paused (`widget.lua:22,34-44`).
- `TintTo` requires the widget to have `SetTint` — `Image` does, **`Text` does not**
  (`uianim.lua:40`); animate text colour with `SetColour` instead.
- Canonical slide-out/slide-back-in: `widgets/upgrademodulesdisplay.lua:634-648`
  (`MoveTo` off-screen, `Hide()` **in the completion callback**, `Show()` + `MoveTo` back);
  crafting menu open/close `widgets/redux/craftingmenu_hud.lua:185,214` (0.25s);
  inventory bar `widgets/inventorybar.lua:376-391`.
- **Widgets have no automatic per-frame Update** — the old recursive `Widget:Update` is
  commented out (`widgets/widget.lua:493-504`). Opt in with `StartUpdating()` /
  `StopUpdating()` (`widget.lua:485-491`), which register with
  `TheFrontEnd:StartUpdatingWidget` and call the widget's `OnUpdate(dt)` while enabled
  (`frontend.lua:888-895`). A mod HUD widget must call `StartUpdating()` itself.
- `DoTaskInTime` / `DoPeriodicTask` are **EntityScript** methods; the `Widget` class has
  none. Use `self.inst:DoTaskInTime(...)` / `self.inst:DoPeriodicTask(...)` (vanilla:
  `widgets/badge.lua:174,188`). The Widget ctor rebinds the inst's tasks to the static
  scheduler so they keep running while paused (`widget.lua:37-41`).
- `Show()` / `Hide()` exist (`widgets/widget.lua:311,318`); **there is no `SetShown`**.
  `Hide()` is instantaneous, so animate first and hide in the callback. `Hide()` does not
  clear focus — call `ClearFocus()` (`widget.lua:615`) before hiding, since a focused
  hidden button can still fire from keyboard/controller.
- **`Widget` has no `SetOnClick`.** Clickable widgets are `Button`/`ImageButton`:
  `Button:SetOnClick(fn)` (`widgets/button.lua:235`), `ImageButton(atlas, normal, focus,
  disabled, down, selected, scale, offset)` (`widgets/imagebutton.lua:4`). Vanilla's own
  collapse toggle is an `ImageButton` with `SetOnClick`
  (`widgets/redux/craftingmenu_pinbar.lua:32,70-76`). Mark decorative children
  `SetClickable(false)` (`widget.lua:526`) so they do not swallow hits, and `Disable()` a
  panel while it animates off-screen.
- **HUD buttons get focus from the mouse hover, not from `SetFocus`.** Every frame the
  frontend runs `DoHoverFocusUpdate` (`frontend.lua:932-942`): it takes
  `TheInput:GetAllEntitiesUnderMouse()`, and `hover_inst.widget:SetFocus()` on the
  topmost UI entity. `SetFocus` calls `SetFocusFromChild` up the parent chain, which is
  how `CONTROL_ACCEPT`/`CONTROL_PRIMARY` then reach `Button:OnControl`. Consequences for
  a mod HUD widget: (a) the button's image quad is the hit region, so size it with
  `ImageButton:ForceImageSize(w, h)` (`widgets/imagebutton.lua:34-38`); (b) every
  decorative `Image`/`Text` in the card must be `SetClickable(false)` or it wins the
  hover and the button never fires.
- `Widget:Kill()` (`widgets/widget.lua:325`) removes the widget from its parent, kills all
  children and calls `inst:Remove()`. It is the clean way to tear down dynamic children
  (e.g. rebuilding HUD rows) before re-adding them — do **not** just drop references.
- **Dragging a HUD widget horizontally** (verified in the scripts 2026-11-13; the tracker
  uses this for its per-player position):
  - Input reaches a widget only through **focus**. `FrontEnd:OnMouseButton`
    (`frontend.lua:1287-1297`) dispatches to the top screen, and `Widget:OnMouseButton`
    (`widget.lua:56-62`) / `Widget:OnControl` (`:124-139`) forward only down the focused
    child chain. Hover focus comes from `FrontEnd:DoHoverFocusUpdate`
    (`frontend.lua:932-942`) via `TheInput:GetAllEntitiesUnderMouse()`, so the drag handle
    must be **clickable** and under the mouse. A zero-size container cannot be hovered:
    add a child `Image("images/ui.xml", "blank.tex")` sized to the panel with
    `Image:SetSize` and `SetClickable(true)` — the same blank texture
    `TEMPLATES.InvisibleButton` uses (`widgets/templates.lua:858-860`). Add it **first** so
    buttons added later stay in front (`entitiesundermouse[1]` is the front-most,
    `input.lua:516-518`).
  - **Mouse clicks are dispatched as `CONTROL_ACCEPT`**, not `CONTROL_PRIMARY`:
    `frontend.lua:437-440` maps `CONTROL_PRIMARY → CONTROL_ACCEPT` before the screen sees
    it. Consume a card click by returning true from `OnControl(CONTROL_ACCEPT, down)`; if
    nothing consumes it, `PlayerHud:OnControl` (`screens/playerhud.lua:1436-1441`) falls
    through to the player controller and the click moves/attacks toward the cursor.
  - **`TheInput:GetScreenPosition()` is directly comparable to `Widget:GetWorldPosition()`**
    — it returns `TheSim:GetPosition()` (`input.lua:246-249`), and vanilla
    `widgets/mousetracker.lua:35-40` subtracts the two. A mouse delta becomes a local delta
    in a scaled HUD root by dividing by `parent:GetScale().x` (**not** `GetWorldScale`,
    which is missing in this build — see above).
  - `button` is a `MOUSEBUTTON_*` constant (`MOUSEBUTTON_LEFT = 1000`, `constants.lua:396`).
    `TheInput:IsMouseDown(button)` polls the held state (`input.lua:294-296`); vanilla's map
    drag instead polls `TheInput:IsControlPressed(CONTROL_PRIMARY)` in `OnUpdate`
    (`widgets/mapwidget.lua:84-105`) — either works.
  - `TheInput:AddMouseButtonHandler` (`input.lua:131-133`) receives every mouse event
    regardless of focus (used by `widgets/scripterrorwidget.lua:20`), but nothing removes it
    for a widget: `Widget:Kill` only calls `StopUpdating()` (`widget.lua:325`). Prefer the
    focused-widget `OnMouseButton` route plus `StartUpdating()`/`OnUpdate` polling, which
    dies with the widget.
  - `Widget:StartUpdating()`/`StopUpdating()` drive `OnUpdate(dt)` every frame
    (`frontend.lua:883-896`); stop updating when the drag ends, and note `Widget:Kill`
    stops it for you.
- A `Widget` has no `SetSize`; sizing lives on the concrete widget types
  (`Image:SetSize`, `Text:SetSize`, `NineSlice:SetSize`, `Panel:SetSize`). A plain
  container `Widget` is zero-size and position-only, so its children's positions are in
  its local coordinate space.
- **`Widget:SetScissor(x, y, w, h)`** (`widgets/widget.lua:836`) puts a scissor on the
  widget's UI transform; children are clipped to it. The rect is anchored **bottom-left**,
  not centred (`widgets/truescrollarea.lua:27-29`, `widgets/redux/scrapbookscreen.lua:2236`).
  This is the clean way to draw oversized art: e.g. a side plank texture at its natural
  aspect (so it is not squashed into a blurry smear) cropped to the panel window. Without
  it, scaling `side.tex` (44x1023) down to a ~140 px-tall panel is a 7x anisotropic
  minification and looks visibly soft.

### Installed HUD mods (observed 2026-10-31)

- **Combined Status** (`mods/workshop-1896968971`) scales only
  `controls.topright_root` to `GetHUDScale() * HUDSCALEFACTOR` (`modmain.lua:350`), and
  sets the vanilla clock and its own season dial to `0.8` each. Verified in-game with
  this mod's tracker present: `hudscale=1.11 topright=1.39 seasonclock=1.11`, i.e. the
  values are exactly Combined Status's own configuration — this mod changes none of them.
  Its season dial nonetheless looks oversized next to the clock because
  `scripts/widgets/seasonclock.lua` never applies the `SetScale(0.5)` that vanilla
  `widgets/uiclock.lua:83` applies to the same 215 px `clock_NIGHT.tex`/`clock_rim.tex`.
  The dial is therefore ~2x the clock face regardless of any other mod; it is a
  Combined Status quirk, not a shared-root conflict.

## Client-side persistence (verified; used for the tracker drag position)

- `TheSim:GetPersistentString(filename, cb)` → `cb(success, data)`;
  `TheSim:SetPersistentString(filename, data, encode, cb)`; also
  `TheSim:ErasePersistentString` (`scripts/mainfunctions.lua:44-71`). Vanilla client HUD
  code uses it: `scripts/craftingmenuprofile.lua:41,47`. The callback is optional on a
  write (`scripts/cookbookdata.lua:21`, `scripts/loadingtipsdata.lua:24`).
- It works on clients that are **not** the host; files land in the per-account
  `client_save/` directory. Mods conventionally use `mod_config_data/<Name>`. Do not
  repurpose `TheSim:SetSetting`/`client.ini` for mod data.
- The tracker stores its per-player drag offset in
  `mod_config_data/guidedmissions_tracker_position` (a plain number as text). Mission
  state itself stays server-side; only this display preference is client-local. Nothing
  is written unless the player actually moves the card.

## Entity helpers used by this mod

- `inventory:ForEachItem(fn, ...)` (`components/inventory.lua:667`).
- `stackable:StackSize()` (`components/stackable.lua:59`).

## Performance measurement (verified tooling)

- `gamelogic.lua:10` requires `perfutil.lua`, so `CountEntities()` is defined in the
  **server** Lua state. It walks `Ents` — loaded entities only — and prints totals plus
  a per-prefab breakdown. `c_countprefabs(prefab)` (`consolecommands.lua:905`) returns
  a single count the same way. Counts move with player position because DST unloads
  distant entities.
- `c_netstats()` (`consolecommands.lua:1231`) prints `TheNet:GetNetworkStatistics()`;
  the keys are engine-defined, so print them once before writing a parser.
- `main.lua:226` requires `profiler.lua`, so `newProfiler(method, sampledelay)`,
  `:start()`, `:stop()` and `:report()` are globals in **both** Lua states.
  `report()` returns a string (it does not write a file); call `print(profiler:report())`
  from the console. Time mode costs roughly 10% while running (`profiler.lua:32-35`).
  It profiles the whole state, so look for `guidedmissions/*` frames in the output.
- `profiler.lua:3` does `os.clock = walltime`. `walltime` is engine-bound (no Lua
  definition); it is the wall-clock timer to use for timing one function call.
- `GetTime()` is `TheSim:GetTick() * ticktime` (`mainfunctions.lua:590-593`). It is
  tick-based, so it does **not** advance inside a single tick — never use it to time a
  function call. Use `walltime` instead.
- Debug keys are dev-build only: `CHEATS_ENABLED = CONFIGURATION ~= "PRODUCTION"`
  (`main.lua:63`) and `debugkeys.lua` is required only when that holds
  (`main.lua:541-543`). Retail therefore has no Ctrl+F1 perf graph
  (`TheSim:TogglePerfGraph`, `debugkeys.lua:281-285`) and no Alt+KP_Divide frame
  profiler (`TheSim:ToggleFrameProfiler`, `debugkeys.lua:1242-1245`). The `TheSim:*`
  methods are engine-bound; calling them from the console may work, but these scripts
  do not guarantee it.

## Translation and locale

Verified 2026-11-13 against build 762172. This is about DST's *text* localization; the
`## Language` section below is about the Lua runtime and is unrelated.

- **`LOC` is a global** created at `scripts/main.lua:195`, before mods load.
  `LOC.GetLocaleCode()` (`scripts/languages/loc.lua:82-89`) returns a lowercase code:
  `en, fr, es, mex, tr, de, it, pt, pl, ru, ko, zh, zht, zhr` (`loc.lua:5-17`; the
  numeric `LANGUAGE` enum is `constants.lua:2605-2631`). Brazilian Portuguese is
  **`pt`**, Simplified Chinese **`zh`**, Traditional **`zht`**, WeGame Simplified
  **`zhr`**, Latin American Spanish **`mex`**.
- **Japanese is not an active locale.** `LANGUAGE.JAPANESE` exists
  (`constants.lua:2627`) and Steam's `japanese` maps to it
  (`LANGUAGE_STEAMCODE_TO_ID`, `constants.lua:2647`), but the localization entry is
  **commented out** in `loc.lua` (the `{id = LANGUAGE.JAPANESE, ..., code = "ja"}` line
  after `zhr`). `GetLocaleCode` therefore never returns `ja`; a shipped `ja` table is
  dormant until Klei enables it.
- **Call it with a dot, not a colon.** `GetLocaleCode(lang_id)` has no `self`; vanilla
  calls `LOC.GetLocaleCode()` (`screens/redux/servercreationscreen.lua:350`,
  `modindex.lua:602`). `LOC:GetLocaleCode()` passes the table as `lang_id`, matches no
  locale entry, and silently returns `"en"`.
- **On Steam the in-game language menu only offers English, Simplified Chinese,
  and Traditional Chinese.** `LOC.GetLanguages()` (`loc.lua:44-73`) always adds
  `LANGUAGE.ENGLISH`, then adds a locale only when `IsSteam()` and
  `in_steam_menu = true` (`loc.lua:15-16`; `in_console_menu` is the console list).
  The Options screen builds its language buttons from that list
  (`screens/redux/optionsscreen.lua:1341-1344`). Below it, under the
  `STRINGS.UI.OPTIONS.MOD_LANGUAGES_TITLE` heading — literally **"Steam Workshop
  Collections"** (`strings.lua:11015`) — the screen fetches
  `https://dst-translation-mods.klei.com/mods.json` and each button opens the
  Workshop page (`optionsscreen.lua:1345-1375`; `_BuildModLangButton`). Picking a
  pack does not change the game's language setting.
- **Steam Workshop language packs are client-only mods that call
  `LoadPOFile(path, code)`.** That stores the PO under `code` and sets
  `LanguageTranslator.defaultlang = code` (`translator.lua:136`); the
  post-mod `TranslateStringTable(STRINGS)` pass (`main.lua:399-402`) applies it.
  It does **not** call `LOC.SetCurrentLocale` or `Profile:SetLanguageID`, so for a
  French/German/etc. pack user `LOC.GetLocaleCode()` still returns `"en"`.
  `LanguageTranslator.defaultlang` is the reliable signal for the effective UI
  language, and it is what `L10n.GetLocale` checks before `LOC`.
- **Pack codes are arbitrary.** They are whatever the pack passes to
  `LoadPOFile`, not necessarily DST's own codes (the community Brazilian pack
  uses `"br"`, not `"pt"`). Normalise variants and ignore codes the mod does not
  ship.
- **There is no `AddModTranslationString`** in this build, and no automatic mod PO
  loader. Don't search for one; the single-player Don't Starve API differs.
- **`LoadPOFile` exists but is unsafe for mods.** `scripts/modutil.lua:836-840` injects
  `env.LoadPOFile(path, lang)`, which calls `LanguageTranslator:LoadPOFile`. That call
  **replaces** `self.languages[lang]` and sets `self.defaultlang`
  (`scripts/translator.lua:67-138`), so it disturbs other mods and the final
  `TranslateStringTable(STRINGS)` pass at `main.lua:402`. This mod uses its own tables
  in `scripts/guidedmissions/l10n.lua`; see `docs/localization.md`.
- **Locale is per Lua VM.** The dedicated server picks the cluster language
  (`TheNet:GetDefaultServerLanguage()`), a client picks its own
  (`Profile:GetLanguageID()`) — `scripts/languages/language.lua:7-25`. On Steam the
  profile value can only be `en`, `zh`, or `zht` (the menu above); other client
  languages exist only as language-pack mods. Each VM translates its own
  `STRINGS`; nothing propagates translations over the network.
- **Netvars carry raw bytes.** Server-resolved text reaches every client in the
  **server's** language (examine text and `TheNet:Announce` are the obvious examples).
  To localize per client, send the source text/key and resolve it on the receiving
  client — which is what this mod does.
- **Localized prefab names:** `STRINGS.NAMES[prefab:upper()]` on the client, as vanilla
  crafting UI does (`widgets/redux/craftingmenu_details.lua:253`) and as
  `named_replica.lua:1-4` fall back to. This mod instead embeds display names inside
  translated `label`/`hint` sentences.
- **Font widths for layout budgets:** the mod's primary BMFonts are Latin-only and
  condensed. DST falls back to Noto outline fonts (`scripts/fonts.lua:50-62`): CJK
  glyph advances are ~2.8–2.9× an average Latin glyph at the same size, and
  Cyrillic/Greek are ~1.8–2.1×. That is why `l10n.DisplayWidth` weights Cyrillic as 2
  and CJK as 3.
- **Fallback font atlases are BMFont packed mode.** `fonts/fallback_outline.zip` is
  DXT5; `fonts/fallback_full_outline_packed.zip` is uncompressed RGBA and declares
  `common packed="1"` with a per-char `chnl` (1=blue, 2=green, 4=red, 8=alpha). The
  glyph lives in that channel, not in RGB. `tests/preview/render.py` decodes this so
  Russian and Chinese previews render.
- **`modinfo.lua` has its own translation hook:** the mod-info environment supplies
  `locale` and `ChooseTranslationTable(tbl)` (`scripts/modindex.lua:598-606`). The mod
  does not use it yet, so configuration labels remain English.

## Language

DST uses Lua 5.1 with a trimmed standard library: no `goto`, no `//` integer division,
no bitwise operators, no `table.pack`. Stay within that.

**Verified 2026-10-31 on Windows:** the shipped executables embed vanilla **Lua 5.1.4**,
not LuaJIT — all four of `bin/dontstarve_steam.exe`, `bin64/dontstarve_steam_x64.exe`,
`bin/dontstarve_dedicated_server_nullrenderer.exe`, and
`bin64/dontstarve_dedicated_server_nullrenderer_x64.exe` contain the string `Lua 5.1.4`
and no `LuaJIT` string. Check from a shell:

```bash
grep -a -o -m1 "Lua [0-9.]*" "<steam>/bin/dontstarve_steam.exe"
grep -a -m1 "LuaJIT" "<steam>/bin/dontstarve_steam.exe" || echo "no LuaJIT"
```

Check at runtime in the in-game console (`~`), which uses the same Lua state as mod code.
Run it once in the client state and once in the server state (dedicated servers may
differ): `print(_VERSION)` prints `Lua 5.1`; `print(jit and jit.version or "no LuaJIT")`
distinguishes vanilla from LuaJIT. A non-Windows/dedicated build should be re-verified
this way rather than assumed.
