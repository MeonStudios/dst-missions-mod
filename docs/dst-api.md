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
- `AddPlayerPostInit` is defined in `modutil.lua` (~line 586) as
  `AddPrefabPostInitAny` plus a `player` tag filter; it runs on server and client.

## Player hooks and events

- Event payloads, all pushed on the player that acted:
  - `itemget` → `{ item = <entity>, slot = ..., src_pos = ... }`, pushed by
    `components/inventory.lua` (~lines 1020 and 1151).
  - `builditem` → `{ item = <entity>, recipe = <recipe>, skin, prototyper }`, pushed by
    `components/builder.lua` (~line 741).
  - `killed` → `{ victim = <entity>, attacker = <entity>, ... }`, pushed on the
    **attacker/doer**, not the victim (`components/combat.lua:682`, also `actions.lua`).
    Listening on the player is therefore correct for kill objectives.
- `playeractivated` is pushed to `TheWorld` in `prefabs/player_common.lua` (~line 826),
  after `ActivateHUD` has already run `hud:SetMainCharacter(inst)`.

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
- The dirty event fires *before* the Lua update runs. In this mod all three tracker
  strings share one dirty event so the client re-renders once per state change.

## Text and HUD

- `Text(font, size, text, colour)` — font first. `DEFAULTFONT = "opensans"`
  (`scripts/fonts.lua`). `Text:SetHAlign` / `Text:SetVAlign` are in
  `scripts/widgets/text.lua`.
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

## Entity helpers used by this mod

- `inventory:ForEachItem(fn, ...)` (`components/inventory.lua:667`) and
  `inventory:GiveItem(item, slot, src_pos)` (`:1029`).
- `stackable:StackSize()` (`components/stackable.lua:59`).
- `SpawnPrefab(prefab)` is engine-bound and server-side only.

## Language

DST is Lua 5.1 / LuaJIT: no `goto`, no `//` integer division, and a trimmed standard
library. Stay within that.
