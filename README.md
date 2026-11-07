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

`label` is optional. `collect` reads the player's inventory, so the starting
inventory counts and stacked pickups register; the progress is peak holdings, so
spending or dropping items later does not remove credit. `craft` and `build` are
deliberately separate: torches, spears, and other carryable products are `craft`;
firepits, Science Machines, walls and other placed objects are `build`. Using the
wrong type for a prefab means that objective never completes. Prefab ids are the
game's internal ids (e.g. `log`, `torch`, `firepit`, `researchlab` for the Science
Machine).

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
