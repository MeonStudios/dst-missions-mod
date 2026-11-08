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

If a signature is in doubt, check here rather than guessing — DST's API is loosely
documented and version-dependent.

## Mod metadata (`modinfo.lua`)

- `api_version = 10` for DST.
- Requires `dst_compatible = true`, `all_clients_require_mod = true`, `client_only_mod = false`.

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
      from `itemget`.** `collect` objectives are inventory-derived: the poller takes
      the peak `inventory:ForEachItem` count (see `objectives.lua`
      `ReconcileProgress`), which also survives spending or dropping the items.
  - `gotnewitem` → `{ item, slot }` fires for stack merges too (`inventory.lua:1100`),
    but it *also* fires when a player moves an item into a carried container such as
    their own backpack (`components/container.lua` ~491/508). It is a pickup-sound
    event, not a reliable "acquired something new" signal; do not use it to grant
    collect progress. Reconcile collect objectives against
    `inventory:ForEachItem` instead (see `objectives.lua` `ReconcileProgress`).
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
  the fields avoids relying on when the tag was applied.
- `Inventory:ForEachItem` (`components/inventory.lua:667-685`) visits item slots, equip
  slots, the active/cursor item and the overflow container. It does **not** recurse into
  a worn backpack's contents.

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
- The dirty event fires *before* the Lua update runs. In this mod all four tracker
  strings (`title`, `subtext`, `rows`, `state`) share one dirty event so the client
  re-renders once per state change.
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
  `GetWorldScale()` (`:548`), `GetPosition()` (parent space, `:340`) and `GetChildren()`
  (`:262`) — but no `GetSize`/`GetBoundingBox` (only `Panel`/`Image` have sizes).
  To hug a HUD element, take the extreme world position of its children and back off by
  half the element's art width: `guidedmissiontracker.lua:MeasureRightMargin` does this
  for the status badges so the card sits left of them whatever size they are.
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
  `petals.tex` and `healingsalve.tex` exist (icons for mine / pick / heal rows), while
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
- **Sanity brain art**: `images/global_redux.xml` (`prefabs/global.lua:456`) contains
  `status_sanity.tex` and `status_sanity_bad.tex` (128x128 brain glyphs with a soft dark
  halo, transparent outside it) — the sanity badge art. `images/scrapbook_icons1.xml` also has
  `icon_sanity.tex` (124x124 brain in an orange badge). The tracker maps the icon id
  `brain` to `status_sanity.tex` via a small override table; neither id is an inventory
  item.
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
  `Image:SetTint(unpack(UICOLOURS.X))`.
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
  `HIGHLIGHT_GOLD`, `GOLD_FOCUS`, `BROWN_MEDIUM`, `BROWN_DARK`, `IVORY`, `IVORY_70`.
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

## Client-side persistence (verified, not used here)

- `TheSim:GetPersistentString(filename, cb)` → `cb(success, data)`;
  `TheSim:SetPersistentString(filename, data, encode, cb)`; also
  `TheSim:ErasePersistentString` (`scripts/mainfunctions.lua:44-71`). Vanilla client HUD
  code uses it: `scripts/craftingmenuprofile.lua:41,47`.
- It works on clients that are **not** the host; files land in the per-account
  `client_save/` directory. Mods conventionally use `mod_config_data/<Name>`. Do not
  repurpose `TheSim:SetSetting`/`client.ini` for mod data.
- This mod deliberately keeps tracker state session-only (no file), so none of this is
  currently wired up.

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
