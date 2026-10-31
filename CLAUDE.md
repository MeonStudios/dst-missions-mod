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
| `scripts/widgets/guidedmissiontracker.lua` | Client HUD. Text-only, vanilla fonts. |

## Invariants — breaking these breaks the mod

- **Netvars must be declared identically on server and every client**, or entity
  deserialization fails. `netvars.Attach` runs unconditionally on both sides; never skip
  it on one side, even when the tracker is disabled for that player.
- **Authority is server-side.** The server writes `title`, `objectives`, and `footer` as
  netvar strings; clients only render them and never send progress back.
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

- Syntax check: `luac -p <file>` if available. DST bundles no standalone interpreter, so
  otherwise the game log is the first check. See **Troubleshooting** below.
- Host console: `c_save()` to test `OnSave`/`OnLoad`, `c_reset()` for a fresh world.
- Mission state is stored on players, so an existing save retains old progress —
  regenerate the world for a clean test. Test with two or more players where possible.

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
