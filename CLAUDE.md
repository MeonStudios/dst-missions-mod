# CLAUDE.md — Guided Missions (Don't Starve Together)

A DST mod: a configurable, ordered mission chain with a client HUD tracker. Each player
progresses independently; the server owns all state. Target is **DST**, not single-player
Don't Starve — so `all_clients_require_mod = true` and every client must install it.
Lua 5.1/LuaJIT semantics. No build step: this directory *is* the mod folder.

## Where things live

| File | Role |
|---|---|
| `scripts/guidedmissions/missions.lua` | The mission chain. Normally the only file you edit; the objective schema is documented inline. |
| `scripts/guidedmissions/manager.lua` | Server state machine, event listeners, `OnSave`/`OnLoad`. |
| `scripts/guidedmissions/objectives.lua` | Objective labels, progress, matching, completion. |
| `scripts/guidedmissions/netvars.lua` | Every netvar name plus the attach/read/write helpers. |
| `scripts/guidedmissions/settings.lua` | Runtime settings, populated from mod options in `modmain.lua`. |
| `scripts/widgets/guidedmissiontracker.lua` | Client HUD. Renders the netvar string contract as a mission card (crafting-menu frame, item icons, green checks); no game logic. |
| `tests/manager_test.lua` | Plain-Lua logic harness for the server manager. Stubs DST globals and replays the full chain; never loaded by the game. |
| `tests/modmain_test.lua` | Loads the real `modmain.lua` in a sandbox matching DST's mod env (notably **no `tonumber`**) and drives the console commands / RPC handlers. Never loaded by the game. |
| `tests/preview/` | Offline HUD preview: runs the real tracker with stubbed widgets and renders PNGs from the game's atlases/fonts. |

## Invariants — breaking these breaks the mod

- **Netvars must be declared identically on server and every client**, or entity
  deserialization fails. `netvars.Attach` runs unconditionally on both sides; never skip
  it on one side, even when the tracker is disabled for that player.
- **Authority is server-side.** The server writes `title`, `subtext`, `rows`, and `state`
  as netvar strings; clients only render them and never send progress back. The HUD is a
  renderer of that string contract, not a second source of truth.
- **Information only — no gameplay impact.** The mod observes events and world state and
  displays guidance. It must never spawn items, grant rewards, modify stats, or otherwise
  change game state. Mission completion only advances the tracker.
- **Save state is keyed by mission id, not array index**, so inserting or reordering
  missions does not corrupt existing progress. Ids must be unique and stable.
- **Cancel periodic tasks in `OnRemoveFromEntity`.**
- Mission data loads at startup. Editing `missions.lua` needs a server restart (or
  disable/enable the mod); there is no live reload.

## Before touching netvars, the HUD, or event hooks

Read `docs/dst-api.md` — verified signatures for netvars, player event payloads, `Text`,
and HUD attachment, plus how to inspect the installed game scripts when confirming an API.

**Update it as you go.** Every time you look something up or verify an API against the
game scripts — or find that a documented fact is wrong — add or correct it in
`docs/dst-api.md` in the same change. Record the verified behavior and cite the game
script (and line where useful), and remove claims the scripts disprove. Do not leave
the finding only in chat or a code comment: the point of that file is that the next
agent does not have to re-derive it.

## Dev loop

The project is junctioned into the game's mods folder (created 2026-10-31), so edits are
live in-game immediately:

```
<steam>/mods/dst-mission-mod  ->  C:\Users\matti\Documents\Coding\Visual Studio Code projects\dst-mission-mod
```

`<steam>` is `C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together`. If the
junction is missing (e.g. after a reinstall), recreate it with `mklink /J` from an
elevated prompt. It only helps this machine; other players need their own copy.

- **Run every offline check at once** before asking the user to test in-game — syntax,
  manager harness, modmain harness. Stops at the first failure and exits non-zero:

  ```powershell
  .\verify
  ```

  `verify.cmd` at the repo root; it `cd`s to its own directory first, so any working
  directory works. Batch runs in place from PowerShell and cmd (no `.sh` file
  association, so no stray Git Bash window). Override the interpreters with
  `LUA=...` / `LUAC=...`. `tests/preview/run.sh` is still POSIX and needs `sh`.

  The individual checks below are the same commands, kept separate so you know which
  one to reach for while iterating.

- **Run the syntax check after every change**, before asking the user to test in-game.
  Lua 5.1 is installed (`C:\Program Files (x86)\Lua\5.1`) and `luac` is on `PATH`:

  ```bash
  luac -p $(find . -name "*.lua" -not -path "./.git/*")
  ```

  Exit 0 with no output = every file parses. Use `luac`, not `lua`: bare `lua` fails in
  Git Bash because the install's `lua/` module directory shadows `lua.exe` on `PATH`.

- **Run the manager harness** when touching the manager, objective helpers, netvars, or
  the mission chain. It validates the mission data first (known objective types, unique
  ids, prefab-id shape) and stops there on a data error, then runs the real modules with
  stubbed engine globals, replays every mission (including the 3-second hold, the `done`
  payload, save/load, and task cleanup), and exits non-zero on failure:

  ```bash
  "/c/Program Files (x86)/Lua/5.1/lua.exe" tests/manager_test.lua
  ```

  It is a logic check only — rendering, netvar replication, and engine API behavior are
  still verified only by a human running the game.

- **Run the modmain harness** when touching `modmain.lua` (especially the console
  commands or anything that later runs in the mod environment):

  ```bash
  "/c/Program Files (x86)/Lua/5.1/lua.exe" tests/modmain_test.lua
  ```

  It loads the real `modmain.lua` with the same restricted environment DST builds in
  `mods.lua` (`CreateEnvironment`) — a whitelist with no `_G` fallback and no
  `tonumber`. It exercises `c_resetmissions`/`c_setmission` on the server and client
  paths plus the RPC handlers. This catches `attempt to call global 'tonumber' (a nil
  value)` style bugs that the manager harness cannot, because `require()`d modules run
  in the normal global env.

- **Preview the HUD without launching the game.** `tests/preview` runs the *real*
  `widgets/guidedmissiontracker.lua` with stubbed widget classes, dumps its draw tree,
  and renders PNGs using the game's actual KTEX atlases and BMFont glyphs:

  ```bash
  sh tests/preview/run.sh
  ```

  Outputs `tests/preview/out/{active_2row,sanity_2row,active_1row,won,done,collapsed}.png`. Requires
  Pillow (`pip install pillow`). The game data path defaults to the Steam install and is
  overridable with `--game-data` or `DST_DATA`. Because it records the real widget, layout
  changes show up without duplicating constants. It does not exercise input, netvars, or
  the engine's exact glyph hinting — those still need an in-game run. Add a scenario in
  `tests/preview/dump.lua` when you need another state.

  This is a **parser check only** — it does not execute the mod, so it will not catch
  runtime errors, wrong engine-API assumptions, or `strict.lua` undeclared-global errors.
  Those still require the in-game run below. See **Troubleshooting**.
- Host console: `c_save()` to test `OnSave`/`OnLoad`, `c_reset()` for a fresh world.
- Mission state is stored on players, so an existing save retains old progress.
  As an admin/host, open the console (`~`) and run `c_resetmissions()` to restart
  your chain from mission 1, or `c_setmission(n)` (1-based) to jump to any
  mission, without regenerating the world (`modmain.lua` →
  `GuidedMissionManager:JumpTo`). Test with two or more players where possible.

## Troubleshooting (read this before debugging)

Logs are 20-30 KB+ of engine noise. Do **not** dump them. A startup crash is almost
always a mod load error, and the **first** traceback in the server log is the cause;
everything after it is fallout that says nothing new.

Base directory for all logs: `~/Documents/Klei/DoNotStarveTogether` (Windows:
`Documents\Klei\DoNotStarveTogether`).

| What | Where |
|---|---|
| Server logs, hosted world (started from the in-game client) | `master_server_log.txt`, `caves_server_log.txt` in the base dir |
| Server logs, dedicated cluster | `Cluster_*/server_log.txt` |
| Client / HUD / widget errors | `client_log.txt` |

A failed start still writes server logs, but may not create a `Cluster_*` folder.
A log's mtime tells you which run it belongs to.

### 1. Pull only the first error

```bash
cd ~/Documents/Klei/DoNotStarveTogether
grep -n -m1 -A25 -E "MOD ERROR|LUA ERROR|attempt to|Disabling .*because it had an error" \
    master_server_log.txt caves_server_log.txt
```

For HUD/tracker-only problems (client-side Lua), use `client_log.txt` instead:

```bash
grep -n -m1 -A25 -E "LUA ERROR|attempt to" client_log.txt
```

### 2. Read the traceback

- `MOD ERROR ... Error loading mod!` with the top mod frame in a mod file = failure
  inside `modmain.lua` / `require()`. Fix the file:line in the **top mod frame**.
- `variable 'X' is not declared` = `scripts/strict.lua`. In a `require()`d module this
  is usually `GLOBAL`; it must be `local GLOBAL = _G` (see Conventions). This exact
  error crashed the first run.
- `attempt to index/call a nil value` at runtime = a wrong API assumption. Verify the
  real signature in the installed game scripts before changing code — see
  `docs/dst-api.md` for the archive path and `unzip -p` recipe.
- `Disabling <mod> because it had an error` = the game turned the mod off. It must be
  re-enabled in the Mods menu after the fix or the next test changes nothing.

### 3. Confirm the mod's own behavior

```bash
grep "Guided Missions" master_server_log.txt
```

All runtime prints from this mod use the `[Guided Missions]` prefix.

### 4. Verify the API before changing code

Function signatures and engine globals are easy to get wrong, and a wrong assumption
is a runtime crash rather than a syntax error. `docs/dst-api.md` has a **Fast lookup**
table mapping questions to the exact game script file. Read the game scripts instead
of reasoning from memory:

```bash
unzip -p "<steam>/data/databundles/scripts.zip" scripts/components/combat.lua
```

Never scan the whole archive with a per-file `unzip -p` loop (it takes minutes);
extract once to a temp dir and grep, or open the known file. Components live under
`scripts/components/`, not `scripts/`. Engine-bound globals (`net_string`, `TheNet`,
`SpawnPrefab`) have no Lua definition — verify them from usage.

### 5. Reproduce — this is a **human step**

An agent cannot launch DST, click through the Mods menu, or start a world. Do not
claim a fix is verified because the code looks right or parses: verification means a
human ran the game and a log exists from that run. Ask the user to do it, then read
the newest log:

1. Re-enable the mod in **Mods** (the game disables it after a load error).
2. Start a new world.
3. Send back / point at the newest `master_server_log.txt` (or `client_log.txt` for HUD
   issues), or let the agent read it if it has file access.

A world that failed to start leaves no save to clean up. Change one thing at a time
and disable other mods when isolating a load failure (another mod's error can appear
before ours).

## Conventions

- Use prefab ids in mission data (`log`, `firepit`, `researchlab`). Resolve display names
  through `STRINGS.NAMES` with a fallback so a custom prefab cannot crash the tracker.
- Keep netvar names in `netvars.lua` only, prefixed `guidedmissions.`.
- `GLOBAL` exists only in the modmain environment. Files loaded with `require()` (everything
  under `scripts/`) must use `local GLOBAL = _G`; DST's strict mode errors on `GLOBAL`
  there. Widget code uses normal client-script style, where `Class`, `DEFAULTFONT`, and
  anchors are globals.
- No custom art yet. If assets are added they need `.tex`/`.xml` compilation (ktools) and
  an `Assets` entry in `modmain.lua`.
