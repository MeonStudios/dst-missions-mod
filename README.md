# Guided Missions

A configurable mission-chain mod for **Don't Starve Together**. It gives each player an
ordered list of objectives and a small HUD tracker, so a group can follow a guided
playthrough. Mission progress is server-authoritative and saved per player.

## Install

1. Copy this folder into your DST mods directory, for example:
   `C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\mods\dst-mission-mod`
2. Start DST, open **Mods**, and enable **Guided Missions**.
3. Start or resume a world. All clients must have the mod installed.
4. Optional: use **Mods → Configure** to toggle the tracker or mission announcements.

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
    reward = { { prefab = "axe", count = 1 } }, -- optional
}
```

Supported objective types:

| Type      | Fields            | Completes when |
|-----------|-------------------|----------------|
| `collect` | `prefab`, `count` | the player has acquired `count` of the prefab |
| `build`   | `prefab`, `count` | the player builds `count` of the prefab |
| `kill`    | `prefab`, `count` | the player kills `count` of the prefab |
| `survive` | `day`             | the world reaches that day |

`label` and `reward` are optional. `collect` counts items the player already has when the
mission starts. Prefab ids are the game's internal ids (e.g. `log`, `torch`, `firepit`,
`researchlab` for the Science Machine).

## How it plays

- The tracker appears at the top-left for every player, showing the active mission and
  objective progress.
- Missions advance automatically when all objectives are complete.
- Mission starts and completions are announced in chat (can be disabled).
- After the last mission the tracker shows **All missions complete!**
- Progress is per player and survives save/load.

## Troubleshooting

- **No tracker:** make sure the mod is enabled on the client and `Mission Tracker` is on
  in the mod configuration. Check `client_log.txt` for errors.
- **Can't join a modded server:** every client needs this mod (`all_clients_require_mod`).
- **Mission progress looks stale:** mission data is loaded at startup; restart the world
  after editing `missions.lua`.
- **Testing persistence:** use `c_save()`, then rejoin. For a fresh run, regenerate the
  world or use a new save slot.

## Known limitations

- Progress is per player; there is no shared or team mission state.
- `collect` counts the player's `itemget` event plus starting inventory, so items routed
  directly into an open backpack or chest may not be counted.
- The tracker is text-only with a fixed layout; long objective lists can overflow.
- Completion is announced globally, with no per-player popup.
- No localization, no custom icons, no mission editor UI.

## Roadmap

Mission sets selectable via mod options; admin commands to skip or reset a mission;
shared progress; `visit`, `feed`, `craft recipe`, and `give item` objective types; an
external JSON mission loader.

## Development

No build step is required. Architecture, invariants, conventions, and the testing loop
are in [`CLAUDE.md`](CLAUDE.md); verified DST API details are in
[`docs/dst-api.md`](docs/dst-api.md).
