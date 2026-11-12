-- Server-side logic harness for the guided mission manager.
--
-- Runs the real manager/netvars/objectives modules against a stubbed DST
-- environment. Two independent halves:
--
--   * data validation of the real `missions.lua` (shape only), and a render
--     smoke test that activates every real mission — this deliberately pins no
--     titles, counts, order, or row indexes, so editing the mission chain does
--     not break the harness;
--   * behavioural tests of the manager and every objective type, driven by a
--     synthetic mission chain defined below, not by `missions.lua`.
--
-- The type fixtures are registered in `type_fixtures`; the harness fails if an
-- objective type in `Objectives.VALID_TYPES` has no fixture, so adding a type
-- forces adding coverage.
--
-- This is plain Lua 5.1 — no game and no DST scripts are loaded.
--
-- Run from anywhere:
--
--   "/c/Program Files (x86)/Lua/5.1/lua.exe" tests/manager_test.lua
--
-- (Bare `lua` fails in Git Bash on this machine: the install's `lua/` module
-- directory shadows `lua.exe` on PATH.)
--
-- What this does NOT verify: HUD rendering, netvar replication across the
-- network, engine API behavior, or fonts/atlases. Those still need an in-game
-- run; see the Troubleshooting section of CLAUDE.md.

-- Resolve the repo root from this script's own path so the harness works
-- regardless of the current directory.
local script_path = arg and arg[0] or "tests/manager_test.lua"
local tests_dir = script_path:match("^(.*)[/\\][^/\\]+$") or "."
local root = tests_dir .. "/.."
package.path = root .. "/scripts/?.lua;" .. package.path

-- ---- minimal DST globals -------------------------------------------------

-- Enough of `Class` for a module that defines a class with no base.
function Class(base, ctor)
    if ctor == nil then
        ctor = base
        base = nil
    end
    local cls = {}
    cls.__index = cls
    if base then
        setmetatable(cls, { __index = base })
    end
    setmetatable(cls, {
        __index = base,
        __call = function(c, ...)
            local obj = setmetatable({}, cls)
            ctor(obj, ...)
            return obj
        end,
    })
    return cls
end

-- Netvars are stored per entity GUID and keyed by their network name, so the
-- harness can read exactly what the server would have sent.
local netvars_by_inst = setmetatable({}, { __mode = "k" })
-- Number of `set` calls per entity, so the harness can assert that a Sync with
-- unchanged state writes nothing.
local netvar_writes = {}

function net_string(guid, name, event)
    local store = netvars_by_inst[guid]
    if store == nil then
        store = {}
        netvars_by_inst[guid] = store
    end
    local netvar = {}
    function netvar:set(value)
        store[name] = value
        netvar_writes[guid] = (netvar_writes[guid] or 0) + 1
    end
    function netvar:value() return store[name] or "" end
    return netvar
end

STRINGS = { NAMES = {
    FLINT = "Flint",
    TWIGS = "Twigs",
    LOG = "Log",
    TORCH = "Torch",
    FIREPIT = "Fire Pit",
    SPIDER = "Spider",
    GOLDNUGGET = "Gold Nugget",
    RESEARCHLAB = "Science Machine",
    GOLDENAXE = "Golden Axe",
    AXE = "Axe",
    PICKAXE = "Pickaxe",
    COOKEDMEAT = "Cooked Meat",
    MEATBALLS = "Meatballs",
} }
TheWorld = { state = { cycles = 0 } }
-- Only the identity of these action tables matters (workable.action is compared
-- against ACTIONS.CHOP), so empty tables are enough.
ACTIONS = { CHOP = {}, MINE = {}, DIG = {} }
local announcements = {}
TheNet = { Announce = function(_, message) announcements[#announcements + 1] = message end }

-- Keep the manager's announce chatter out of the PASS/FAIL output.
local real_print = print
function print(...)
    local first = ...
    if type(first) == "string" and first:find("^%[Guided Missions%]") ~= nil then
        return
    end
    real_print(...)
end

-- ---- fake scheduler ------------------------------------------------------

local clock = 0
local tasks = {}

local function NewTask(at, fn, interval, owner)
    local task = { at = at, fn = fn, interval = interval, cancelled = false, owner = owner }
    tasks[#tasks + 1] = task
    if owner ~= nil then
        owner._tasks[#owner._tasks + 1] = task
    end
    function task:Cancel()
        self.cancelled = true
    end
    return task
end

local function Advance(seconds)
    local target = clock + seconds
    while true do
        local soonest, index
        for i, task in ipairs(tasks) do
            if not task.cancelled and (soonest == nil or task.at < soonest.at) then
                soonest, index = task, i
            end
        end
        if soonest == nil or soonest.at > target then
            break
        end
        clock = soonest.at
        if soonest.interval then
            soonest.at = clock + soonest.interval
        else
            table.remove(tasks, index)
        end
        soonest.fn()
    end
    clock = target
end

-- ---- fake player entity --------------------------------------------------

local function NewInst(guid)
    local inst = {
        GUID = guid,
        components = {},
        _listeners = {},
        _tasks = {},
        -- Items the player carries. Collect objectives are reread from this
        -- when an inventory event fires (see objectives.lua
        -- ReconcileProgress), never accumulated from event payloads.
        items = {},
    }
    inst.components.inventory = {
        ForEachItem = function(_, fn)
            for _, item in ipairs(inst.items) do
                fn(item)
            end
        end,
    }
    function inst:ListenForEvent(event, fn)
        self._listeners[event] = self._listeners[event] or {}
        table.insert(self._listeners[event], fn)
    end
    function inst:DoPeriodicTask(period, fn)
        return NewTask(clock + period, fn, period, self)
    end
    function inst:DoTaskInTime(delay, fn)
        return NewTask(clock + delay, fn, nil, self)
    end
    function inst:GetDisplayName() return "Wilson" end
    function inst:IsValid() return true end
    function inst:Fire(event, data)
        for _, fn in ipairs(self._listeners[event] or {}) do
            fn(self, data)
        end
    end
    return inst
end

-- The walkthrough player; assigned once the manager module is loaded below.
local inst

local function Read(target)
    return netvars_by_inst[(target or inst).GUID] or {}
end

-- ---- harness -------------------------------------------------------------

local Netvars = require("guidedmissions/netvars")
local Objectives = require("guidedmissions/objectives")
local RealMissions = require("guidedmissions/missions")

local failures = 0

local function Check(label, cond)
    if cond then
        print("PASS  " .. label)
    else
        failures = failures + 1
        print("FAIL  " .. label)
    end
end

-- Split the packed row string into `{ label, prefab, counter, done }` tables.
local function Rows(rows)
    local out = {}
    for part in string.gmatch(rows .. ";", "([^;]*);") do
        local fields = {}
        for field in string.gmatch(part .. "|", "([^|]*)|") do
            fields[#fields + 1] = field
        end
        out[#out + 1] = fields
    end
    return out
end

local function Item(prefab, stack_size)
    local item = { prefab = prefab, components = {} }
    if stack_size ~= nil then
        item.components.stackable = { StackSize = function() return stack_size end }
    end
    return { item = item }
end

local function Build(prefab)
    return { recipe = { name = prefab }, item = { prefab = prefab, components = {} } }
end

-- Add a stack of `prefab` to the player's inventory. Collect objectives reread
-- this after an inventory event (the event payload carries no count).
local function Carry(target, prefab, count)
    target.items[#target.items + 1] = {
        prefab = prefab,
        components = { stackable = { StackSize = function() return count end } },
    }
end

-- Add an edible item stack. `secondaryfoodtype` is how berries and
-- berries_juicy share the BERRY tag despite being main-type VEGGIE.
local function CarryFood(target, prefab, count, foodtype, secondaryfoodtype)
    target.items[#target.items + 1] = {
        prefab = prefab,
        components = {
            stackable = { StackSize = function() return count end },
            edible = { foodtype = foodtype, secondaryfoodtype = secondaryfoodtype },
        },
    }
end

-- Signal an inventory change the way the game does and let the manager's
-- deferred reread run. Any of the four gain events triggers it; the value
-- always comes from the `items` table, not from the payload.
local function InventoryChanged(target)
    target:Fire("gotnewitem", {})
    Advance(0)
end

-- Workable targets for chop/mine objectives: `HasTag` plus a workable
-- component.
local function Target(tags, action, workleft)
    local target = {
        components = { workable = { action = action, workleft = workleft } },
    }
    function target:HasTag(tag) return tags[tag] == true end
    return target
end

-- 0. Mission data sanity, against the real missions.lua. An objective with a
-- misspelt type (`cood`) or a placeholder prefab (`food??`) parses cleanly and
-- then silently matches nothing — the mission simply never completes, with no
-- error anywhere. This checks the authoring contract only; it intentionally
-- pins no titles, counts, order, or row positions, so mission edits that keep
-- the schema valid pass.
--
-- The harness cannot know which prefabs the installed game ships (that needs
-- the game scripts), so this checks shape only: prefab and icon ids are
-- lowercase ids (`log`, `cookedmeat`, `berries_juicy`).
local function IsPrefabId(value)
    return type(value) == "string" and value:find("^[a-z0-9_]+$") ~= nil
end

local needs_prefab = {
    collect = true, craft = true, build = true, kill = true, eat = true, pick = true,
}
-- `cook`/`cookpot` take an optional prefab (a dish filter), `prototype` takes
-- one (a recipe id) and `plant` takes one (a seed filter); every other type
-- either ignores the field or does not have one.
local optional_prefab = { cook = true, cookpot = true, prototype = true, plant = true }

local seen_ids = {}
for i, mission in ipairs(RealMissions) do
    local where = string.format("mission %d (%s)", i, tostring(mission.id))
    local id = mission.id
    Check(where .. " has a unique id",
        IsPrefabId(id) and seen_ids[id] == nil)
    if type(id) == "string" then
        seen_ids[id] = true
    end
    Check(where .. " has a title",
        type(mission.title) == "string" and #mission.title > 0)
    Check(where .. " has a subtext",
        type(mission.subtext) == "string" and #mission.subtext > 0)
    Check(where .. " has an objective list",
        type(mission.objectives) == "table" and #mission.objectives > 0)

    for j, objective in ipairs(mission.objectives or {}) do
        local row = string.format("%s objective %d (%s)", where, j, tostring(objective.type))
        Check(row .. " uses a known type", Objectives.VALID_TYPES[objective.type] == true)

        if needs_prefab[objective.type] then
            Check(row .. " names a prefab id", IsPrefabId(objective.prefab))
        elseif not optional_prefab[objective.type] and objective.type ~= "survive" then
            -- A prefab field on a type that ignores it is almost always a
            -- `collect`/`collect_food` mix-up; the two read different events.
            Check(row .. " does not set a prefab", objective.prefab == nil)
        elseif objective.prefab ~= nil then
            Check(row .. " prefab filter is a prefab id", IsPrefabId(objective.prefab))
        end

        Check(row .. " has a label",
            type(objective.label) == "string" and #objective.label > 0)
        if objective.icon ~= nil then
            Check(row .. " icon is a prefab id", IsPrefabId(objective.icon))
        end

        if objective.type == "survive" then
            Check(row .. " has a day", tonumber(objective.day) ~= nil)
        else
            Check(row .. " has a count", tonumber(objective.count) ~= nil)
        end
    end
end

-- Bad mission data also breaks the real-mission render smoke below, so report
-- the data problem and stop rather than bury it in a cascade of failures.
if failures > 0 then
    print("FAILURES: " .. failures .. " in mission data; remaining checks skipped")
    os.exit(1)
end

-- ---- synthetic chain for manager mechanics -------------------------------
--
-- The manager binds `Missions` at require time. Swap in a minimal chain so the
-- mechanics tests below never depend on the real mission content. The real
-- data is validated above and render-smoke-tested at the end.

local SyntheticMissions = {
    {
        id = "harness_first",
        title = "Harness First",
        subtext = "First synthetic mission.",
        objectives = {
            { type = "collect", prefab = "flint", count = 3, label = "Collect flint" },
        },
    },
    {
        id = "harness_second",
        title = "Harness Second",
        subtext = "Second synthetic mission.",
        objectives = {
            { type = "collect", prefab = "twigs", count = 10, label = "Collect twigs" },
        },
    },
}
package.loaded["guidedmissions/missions"] = SyntheticMissions
local Manager = require("guidedmissions/manager")

inst = NewInst(1234)
Netvars.Attach(inst)
local manager = Manager(inst)

-- Create a player + manager for a fixture. `Advance(1)` lets Begin activate the
-- synthetic chain, exactly as a joining player would; `setup(inst)` has already
-- run, so components it seeds (builder recipes) are visible to Begin.
local next_guid = 2000
local function Spawn(setup)
    next_guid = next_guid + 1
    local player = NewInst(next_guid)
    if setup ~= nil then
        setup(player)
    end
    Netvars.Attach(player)
    local fixture_manager = Manager(player)
    Advance(1)
    return fixture_manager, player
end

-- Point a fixture manager at a mission defined in the test, with progress
-- seeded exactly as `SetMission` would.
local function Activate(fixture_manager, player, mission)
    fixture_manager.current_mission = mission
    fixture_manager.completed = false
    fixture_manager.progress = {}
    for i, objective in ipairs(mission.objectives) do
        fixture_manager.progress[i] = Objectives.InitialProgress(player, objective)
    end
    fixture_manager:Sync()
end

local function Row(player, index)
    return Rows(Read(player)["guidedmissions.rows"])[index] or {}
end

local function State(player)
    return Read(player)["guidedmissions.state"]
end

-- 1. Startup: the first synthetic mission is active with its row at zero.
Advance(1)
local state = Read()
Check("startup state active", state["guidedmissions.state"] == "active")
Check("startup title", state["guidedmissions.title"] == "Harness First")
Check("startup subtext", state["guidedmissions.subtext"] == "First synthetic mission.")
Check("startup rows count", #Rows(state["guidedmissions.rows"]) == 1)
Check("startup row label", Row(inst, 1)[1] == "Collect flint")
Check("startup row icon", Row(inst, 1)[2] == "flint")
Check("startup row counter", Row(inst, 1)[3] == "0/3")

-- Writing identical tracker strings must not dirty the netvars.
local writes_before = netvar_writes[inst.GUID] or 0
manager:Sync()
Check("sync skips unchanged netvars", (netvar_writes[inst.GUID] or 0) == writes_before)

-- 2. Partial progress ticks without completing. A collect objective is reread
-- on inventory events, so a changed inventory alone moves nothing.
Carry(inst, "flint", 2)
Advance(1)
Check("collect ignores the inventory without an event",
    Row(inst, 1)[3] == "0/3")
InventoryChanged(inst)
Check("partial counter", Row(inst, 1)[3] == "2/3")
Check("still active", State(inst) == "active")

-- 3. Completion writes the `won` payload with the row forced done, announces
-- once, and ignores progress during the 3-second hold.
Carry(inst, "flint", 1)
InventoryChanged(inst)
Check("mission won", State(inst) == "won")
Check("won row done", Row(inst, 1)[4] == "1")
Check("won row counter full", Row(inst, 1)[3] == "3/3")
Check("completion announced in chat",
    announcements[#announcements] == "Wilson completed: Harness First")
Carry(inst, "twigs", 5)
InventoryChanged(inst)
Check("hold still won", State(inst) == "won")

-- 4. After the hold the next mission starts, quietly.
local announce_count = #announcements
Advance(3)
Check("second mission active", State(inst) == "active")
Check("second mission title", Read()["guidedmissions.title"] == "Harness Second")
Check("mission start not announced", #announcements == announce_count)

-- 5. Inventory reconciliation: a pickup that stacks into an existing stack
-- fires no `itemget`, but `gotnewitem` triggers the reread (one tick later,
-- since gotnewitem is pushed before the merge is applied).
Carry(inst, "twigs", 10)
InventoryChanged(inst)
Check("reconcile counts stacked twigs", Row(inst, 1)[3] == "10/10")
Check("reconcile completes mission", State(inst) == "won")
Advance(3)

-- The last mission ends in the terminal `done` payload.
Check("final state done", State(inst) == "done")
Check("final title", Read()["guidedmissions.title"] == "All Missions Complete")
Check("final subtext", Read()["guidedmissions.subtext"] == "You survived. For now.")
Check("final rows empty", Read()["guidedmissions.rows"] == "")

-- 6. Save/load round trip keeps the finished chain finished.
manager:OnLoad(manager:OnSave())
Check("save/load keeps done", State(inst) == "done")

-- 7. Removing the entity during a completion hold cancels every task it made.
local inst2 = NewInst(5678)
Netvars.Attach(inst2)
local manager2 = Manager(inst2)
Advance(1)
manager2.progress[1] = 3
manager2:CheckCompletion()
Check("hold pending after completion", manager2.hold_task ~= nil)
Check("hold payload won", State(inst2) == "won")
manager2:OnRemoveFromEntity()
local live_tasks = 0
for _, task in ipairs(tasks) do
    if task.owner == inst2 and not task.cancelled then
        live_tasks = live_tasks + 1
    end
end
-- Three tasks were created: begin, poll, hold. Begin already ran to completion.
Check("all tasks cancelled on remove", live_tasks == 0 and #inst2._tasks == 3)
Check("hold_task cleared", manager2.hold_task == nil)

-- 8. JumpTo (c_setmission) goes straight to a mission by index, numeric string
-- or mission id, rejects unknown targets, and Reset returns to mission 1.
local inst3 = NewInst(9012)
Netvars.Attach(inst3)
local manager3 = Manager(inst3)
Advance(1)
Check("jump to mission 2 accepted", manager3:JumpTo(2))
Check("jump title", Read(inst3)["guidedmissions.title"] == "Harness Second")
Check("jump state active", State(inst3) == "active")
Check("jump counter", Row(inst3, 1)[3] == "0/10")

Check("jump to a mission id accepted", manager3:JumpTo("harness_first"))
Check("id jump title", Read(inst3)["guidedmissions.title"] == "Harness First")
Check("jump accepts a numeric string", manager3:JumpTo("2"))
Check("numeric string jump title", Read(inst3)["guidedmissions.title"] == "Harness Second")

Check("jump rejects 0", manager3:JumpTo(0) == false)
Check("jump rejects past the end", manager3:JumpTo(#SyntheticMissions + 2) == false)
Check("jump rejects text", manager3:JumpTo("abc") == false)
Check("jump rejects an unknown id", manager3:JumpTo("no_such_mission") == false)
Check("rejected jump changes nothing",
    Read(inst3)["guidedmissions.title"] == "Harness Second")

Check("jump to completion accepted", manager3:JumpTo(#SyntheticMissions + 1))
Check("jump completion state", State(inst3) == "done")

manager3:Reset()
Check("reset title", Read(inst3)["guidedmissions.title"] == "Harness First")
Check("reset state active", State(inst3) == "active")
Check("reset row counter", Row(inst3, 1)[3] == "0/3")

-- ---- objective type fixtures ---------------------------------------------
--
-- One self-contained fixture per type in `Objectives.VALID_TYPES`. They use
-- synthetic missions built here, never `missions.lua`, so mission content edits
-- cannot break them. Adding a type without a fixture fails the completeness
-- check at the bottom.

local type_fixtures = {}

type_fixtures.collect = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_collect",
        title = "Collect",
        subtext = "Items.",
        objectives = {
            { type = "collect", prefab = "flint", count = 3, label = "Collect flint" },
        },
    })
    Check("collect label is rendered", Row(player, 1)[1] == "Collect flint")
    Check("collect icon is the prefab", Row(player, 1)[2] == "flint")
    Check("collect starts at 0/3", Row(player, 1)[3] == "0/3")

    -- `itemget` only triggers a reread; its payload must never be counted.
    -- GiveActiveItem re-fires it whenever an item is clicked onto the cursor,
    -- which was the counter-inflation exploit.
    player:Fire("itemget", Item("flint", 3))
    player:Fire("itemget", Item("flint", 3))
    Check("collect ignores itemget payloads", Row(player, 1)[3] == "0/3")
    Advance(0)
    Check("collect not completed by itemget", State(player) == "active")

    Carry(player, "flint", 2)
    InventoryChanged(player)
    Check("collect counts inventory stacks", Row(player, 1)[3] == "2/3")
    Check("collect stays active below target", State(player) == "active")

    Carry(player, "flint", 1)
    InventoryChanged(player)
    Check("collect completes at target", State(player) == "won")

    -- Peak holdings: spending items later must not remove credit.
    local peak_manager, peak_player = Spawn()
    Activate(peak_manager, peak_player, {
        id = "fixture_collect_peak",
        title = "Collect Peak",
        subtext = "Peak.",
        objectives = {
            { type = "collect", prefab = "log", count = 10, label = "Collect logs" },
        },
    })
    Carry(peak_player, "log", 5)
    InventoryChanged(peak_player)
    Check("peak counts carried stock", Row(peak_player, 1)[3] == "5/10")
    peak_player.items = {}
    InventoryChanged(peak_player)
    Check("peak survives spending", Row(peak_player, 1)[3] == "5/10")
end

type_fixtures.craft = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_craft",
        title = "Craft",
        subtext = "Make it.",
        objectives = {
            { type = "craft", prefab = "axe", count = 1, label = "Craft an axe" },
        },
    })
    Check("craft label is rendered", Row(player, 1)[1] == "Craft an axe")
    Check("craft icon is the prefab", Row(player, 1)[2] == "axe")

    player:Fire("buildstructure", Build("axe"))
    Check("craft ignores buildstructure", State(player) == "active")
    player:Fire("builditem", Build("pickaxe"))
    Check("craft ignores other recipes", State(player) == "active")
    player:Fire("builditem", Build("axe"))
    Check("craft completes on builditem", State(player) == "won")
end

type_fixtures.build = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_build",
        title = "Build",
        subtext = "Place it.",
        objectives = {
            { type = "build", prefab = "firepit", count = 1, label = "Build a Fire Pit" },
        },
    })
    Check("build label is rendered", Row(player, 1)[1] == "Build a Fire Pit")
    Check("build icon is the prefab", Row(player, 1)[2] == "firepit")

    player:Fire("builditem", Build("firepit"))
    Check("build ignores builditem", State(player) == "active")
    player:Fire("buildstructure", Build("firepit"))
    Check("build completes on buildstructure", State(player) == "won")
end

type_fixtures.kill = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_kill",
        title = "Kill",
        subtext = "Fight.",
        objectives = {
            { type = "kill", prefab = "spider", count = 2, label = "Kill spiders" },
        },
    })
    Check("kill label is rendered", Row(player, 1)[1] == "Kill spiders")
    Check("kill icon is the prefab", Row(player, 1)[2] == "spider")

    player:Fire("killed", { victim = { prefab = "rabbit" } })
    Check("kill ignores other victims", Row(player, 1)[3] == "0/2")
    player:Fire("killed", { victim = { prefab = "spider" } })
    Check("kill counts the victim", Row(player, 1)[3] == "1/2")
    player:Fire("killed", { victim = { prefab = "spider" } })
    Check("kill completes at target", State(player) == "won")
end

type_fixtures.survive = function()
    TheWorld.state.cycles = 0
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_survive",
        title = "Survive",
        subtext = "Stay alive.",
        objectives = {
            { type = "survive", day = 3, label = "Survive to day 3" },
        },
    })
    Check("survive label is rendered", Row(player, 1)[1] == "Survive to day 3")
    Check("survive row is text-only", Row(player, 1)[2] == "")
    Check("survive counter starts at day 1", Row(player, 1)[3] == "Day 1/3")

    TheWorld.state.cycles = 1
    Advance(1)
    Check("survive counter follows the world day", Row(player, 1)[3] == "Day 2/3")
    Check("survive stays active early", State(player) == "active")

    TheWorld.state.cycles = 2
    Advance(1)
    Check("survive completes on the target day", State(player) == "won")
    TheWorld.state.cycles = 0
end

type_fixtures.chop = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_chop",
        title = "Timber",
        subtext = "Trees.",
        objectives = {
            { type = "chop", count = 2, label = "Chop down trees" },
        },
    })
    Check("chop label is rendered", Row(player, 1)[1] == "Chop down trees")
    Check("chop icon is axe", Row(player, 1)[2] == "axe")

    player:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 3) })
    Check("partial chop does not count", Row(player, 1)[3] == "0/2")
    player:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
    Check("felled tree counts", Row(player, 1)[3] == "1/2")
    player:Fire("working", { target = Target({ tree = true, stump = true }, ACTIONS.DIG, 0) })
    Check("digging a stump does not count", Row(player, 1)[3] == "1/2")
    player:Fire("working", { target = Target({ tree = true }, ACTIONS.MINE, 0) })
    Check("mining a marble tree does not count", Row(player, 1)[3] == "1/2")
    player:Fire("working", {})
    Check("targetless working is ignored", Row(player, 1)[3] == "1/2")
    player:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
    Check("chop completes at target", State(player) == "won")
end

type_fixtures.mine = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_mine",
        title = "Rock Bottom",
        subtext = "Swing.",
        objectives = {
            { type = "mine", count = 2, label = "Mine boulders" },
        },
    })
    Check("mine label is rendered", Row(player, 1)[1] == "Mine boulders")
    Check("mine icon is pickaxe", Row(player, 1)[2] == "pickaxe")

    player:Fire("working", { target = Target({}, ACTIONS.MINE, 2) })
    Check("partial mine does not count", Row(player, 1)[3] == "0/2")
    player:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
    Check("chopping does not count as mining", Row(player, 1)[3] == "0/2")
    player:Fire("working", { target = Target({}, ACTIONS.DIG, 0) })
    Check("digging does not count as mining", Row(player, 1)[3] == "0/2")
    player:Fire("working", {})
    Check("mine ignores targetless working", Row(player, 1)[3] == "0/2")
    player:Fire("working", { target = Target({}, ACTIONS.MINE, 0) })
    Check("mined node counts", Row(player, 1)[3] == "1/2")
    player:Fire("working", { target = Target({}, ACTIONS.MINE, 0) })
    Check("mine completes at target", State(player) == "won")
end

type_fixtures.eat = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_eat",
        title = "Snack",
        subtext = "Anything is food if you believe.",
        objectives = {
            { type = "eat", prefab = "butterflywings", count = 1, label = "Eat a butterfly wing" },
        },
    })
    Check("eat icon is the prefab", Row(player, 1)[2] == "butterflywings")

    player:Fire("oneat", { food = { prefab = "carrot" } })
    Check("eating other food does not count", State(player) == "active")
    player:Fire("oneat", { food = { prefab = "butterflywings" } })
    Check("eat completes on the target food", State(player) == "won")
end

type_fixtures.heal = function()
    local fixture_manager, player = Spawn(function(target)
        target.components.health = { maxhealth = 100 }
    end)
    Activate(fixture_manager, player, {
        id = "fixture_heal",
        title = "Patch Up",
        subtext = "Ouch.",
        objectives = {
            { type = "heal", count = 20, label = "Restore health" },
        },
    })
    Check("heal label is rendered", Row(player, 1)[1] == "Restore health")
    Check("heal icon is heart", Row(player, 1)[2] == "heart")

    player:Fire("healthdelta", { oldpercent = 0.50, newpercent = 0.56, amount = 6 })
    Check("heal counts the requested amount", Row(player, 1)[3] == "6/20")
    player:Fire("healthdelta", { oldpercent = 0.56, newpercent = 0.50, amount = -6 })
    Check("damage does not count", Row(player, 1)[3] == "6/20")
    player:Fire("healthdelta", { oldpercent = 0.98, newpercent = 1.00, amount = 10 })
    Check("clamped heal counts its full requested amount", Row(player, 1)[3] == "16/20")
    player:Fire("healthdelta", { oldpercent = 1.00, newpercent = 1.00, amount = 0 })
    Check("no-op delta does not count", Row(player, 1)[3] == "16/20")
    player:Fire("healthdelta", { oldpercent = 1.00, newpercent = 1.00, amount = 4 })
    Check("heal completes from overheal at full health", State(player) == "won")
end

type_fixtures.sanity = function()
    local fixture_manager, player = Spawn(function(target)
        target.components.sanity = { max = 100 }
    end)
    Activate(fixture_manager, player, {
        id = "fixture_sanity",
        title = "Settle Down",
        subtext = "Breathe.",
        objectives = {
            { type = "sanity", count = 20, label = "Restore sanity" },
        },
    })
    Check("sanity label is rendered", Row(player, 1)[1] == "Restore sanity")
    Check("sanity icon is brain", Row(player, 1)[2] == "brain")

    player:Fire("sanitydelta", { oldpercent = 0.50, newpercent = 0.56 })
    Check("sanity falls back to the percent difference", Row(player, 1)[3] == "6/20")

    player.components.sanity._guidedmissions_last_delta = 10
    player:Fire("sanitydelta", { oldpercent = 0.98, newpercent = 1.00 })
    Check("sanity counts the recorded requested delta", Row(player, 1)[3] == "16/20")

    player.components.sanity._guidedmissions_last_delta = -10
    player:Fire("sanitydelta", { oldpercent = 1.00, newpercent = 1.00 })
    Check("sanity loss does not count", Row(player, 1)[3] == "16/20")

    player.components.sanity._guidedmissions_last_delta = 4
    player:Fire("sanitydelta", { oldpercent = 1.00, newpercent = 1.00 })
    Check("sanity completes from overflow at full sanity", State(player) == "won")
end

type_fixtures.pick = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_pick",
        title = "Flower Power",
        subtext = "Petals.",
        objectives = {
            { type = "pick", prefab = "flower", count = 2, label = "Pick flowers", icon = "petals" },
        },
    })
    Check("pick row icon override", Row(player, 1)[2] == "petals")

    player:Fire("picksomething", { object = { prefab = "flower_evil" } })
    Check("evil flower does not count", Row(player, 1)[3] == "0/2")
    player:Fire("picksomething", { object = { prefab = "flower" } })
    Check("picked flower counts", Row(player, 1)[3] == "1/2")
    player:Fire("picksomething", { object = { prefab = "flower" } })
    Check("pick completes at target", State(player) == "won")
end

type_fixtures.collect_food = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_food",
        title = "Food for Thought",
        subtext = "Something edible.",
        objectives = {
            { type = "collect_food", count = 3, label = "Collect food" },
        },
    })
    Check("collect_food label is rendered", Row(player, 1)[1] == "Collect food")
    Check("collect_food row is text-only", Row(player, 1)[2] == "")

    Carry(player, "flint", 5)
    InventoryChanged(player)
    Check("non-food does not count", Row(player, 1)[3] == "0/3")

    CarryFood(player, "berries", 2, "VEGGIE", "BERRY")
    InventoryChanged(player)
    Check("food counts stack size", Row(player, 1)[3] == "2/3")

    CarryFood(player, "carrot", 1, "VEGGIE", nil)
    InventoryChanged(player)
    Check("collect_food completes at target", State(player) == "won")

    -- secondaryfoodtype filter: BERRY matches both berries and juicy berries.
    local filter_manager, filter_player = Spawn()
    Activate(filter_manager, filter_player, {
        id = "fixture_berries",
        title = "Berry Picking",
        subtext = "Red and round.",
        objectives = {
            { type = "collect_food", count = 2, secondaryfoodtype = "BERRY", label = "Collect berries" },
        },
    })
    CarryFood(filter_player, "carrot", 2, "VEGGIE", nil)
    InventoryChanged(filter_player)
    Check("non-berry food is filtered out", Row(filter_player, 1)[3] == "0/2")
    CarryFood(filter_player, "berries", 1, "VEGGIE", "BERRY")
    InventoryChanged(filter_player)
    Check("berries count", Row(filter_player, 1)[3] == "1/2")
    CarryFood(filter_player, "berries_juicy", 1, "VEGGIE", "BERRY")
    InventoryChanged(filter_player)
    Check("juicy berries count", State(filter_player) == "won")
end

type_fixtures.plant = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_plant",
        title = "Green Thumb",
        subtext = "Dirt and patience.",
        objectives = {
            { type = "plant", count = 2, label = "Plant seeds" },
        },
    })
    Check("plant label is rendered", Row(player, 1)[1] == "Plant seeds")
    Check("plant default icon is the generic seed", Row(player, 1)[2] == "seeds")

    player:Fire("guidedmissions_plantedseed")
    Check("data-less plantedseed is ignored", Row(player, 1)[3] == "0/2")
    player:Fire("guidedmissions_plantedseed", { seed = "carrot_seeds" })
    Check("planting any seed counts", Row(player, 1)[3] == "1/2")
    player:Fire("guidedmissions_plantedseed", { seed = "seeds" })
    Check("plant completes at target", State(player) == "won")

    -- Optional prefab filters on the seed the player planted.
    local filter_manager, filter_player = Spawn()
    Activate(filter_manager, filter_player, {
        id = "fixture_plant_filter",
        title = "Carrot Patch",
        subtext = "Orange.",
        objectives = {
            { type = "plant", prefab = "carrot_seeds", count = 1, label = "Plant carrot seeds" },
        },
    })
    Check("targeted plant label is rendered", Row(filter_player, 1)[1] == "Plant carrot seeds")
    Check("targeted plant icon is the seed", Row(filter_player, 1)[2] == "carrot_seeds")
    filter_player:Fire("guidedmissions_plantedseed", { seed = "pumpkin_seeds" })
    Check("other seeds are filtered out", State(filter_player) == "active")
    filter_player:Fire("guidedmissions_plantedseed", { seed = "carrot_seeds" })
    Check("targeted plant completes", State(filter_player) == "won")
end

type_fixtures.cook = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_cook",
        title = "Warm Meal",
        subtext = "Fire makes it better.",
        objectives = {
            { type = "cook", count = 2, label = "Cook food" },
        },
    })
    Check("cook label is rendered", Row(player, 1)[1] == "Cook food")
    Check("cook row is text-only without a product", Row(player, 1)[2] == "")

    player:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedmeat" } })
    Check("cooked food counts", Row(player, 1)[3] == "1/2")
    player:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedcarrot" } })
    Check("cook completes at target", State(player) == "won")

    -- Optional prefab filters on the cooked product.
    local filter_manager, filter_player = Spawn()
    Activate(filter_manager, filter_player, {
        id = "fixture_cook_filter",
        title = "Meat Only",
        subtext = "Protein.",
        objectives = {
            { type = "cook", prefab = "cookedmeat", count = 1, label = "Cook meat" },
        },
    })
    Check("cook targeted label is rendered", Row(filter_player, 1)[1] == "Cook meat")
    Check("cook targeted icon is the product", Row(filter_player, 1)[2] == "cookedmeat")
    filter_player:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedcarrot" } })
    Check("other cooked products are filtered out", State(filter_player) == "active")
    filter_player:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedmeat" } })
    Check("cook targeted completes", State(filter_player) == "won")
end

type_fixtures.cookpot = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_cookpot",
        title = "Pot Luck",
        subtext = "Stir.",
        objectives = {
            { type = "cookpot", count = 2, label = "Cook in a Crock Pot" },
        },
    })
    Check("cookpot label is rendered", Row(player, 1)[1] == "Cook in a Crock Pot")
    Check("cookpot row is text-only without a dish", Row(player, 1)[2] == "")

    player:Fire("guidedmissions_cookedfood", { product = { prefab = "meatballs" } })
    Check("fire cooking does not satisfy a cookpot objective",
        Row(player, 1)[3] == "0/2")
    player:Fire("guidedmissions_stewedfood", { product = "wetgoop" })
    Check("any dish counts without a filter", Row(player, 1)[3] == "1/2")
    player:Fire("guidedmissions_stewedfood", { product = "meatballs" })
    Check("cookpot completes at target", State(player) == "won")

    -- Optional prefab filters on the dish.
    local filter_manager, filter_player = Spawn()
    Activate(filter_manager, filter_player, {
        id = "fixture_cookpot_filter",
        title = "Meatballs",
        subtext = "Round.",
        objectives = {
            { type = "cookpot", prefab = "meatballs", count = 1, label = "Cook meatballs" },
        },
    })
    Check("cookpot targeted label is rendered", Row(filter_player, 1)[1] == "Cook meatballs")
    Check("cookpot targeted icon is the dish", Row(filter_player, 1)[2] == "meatballs")
    filter_player:Fire("guidedmissions_stewedfood", { product = "wetgoop" })
    Check("other dishes are filtered out", State(filter_player) == "active")
    filter_player:Fire("guidedmissions_stewedfood", { product = "meatballs" })
    Check("cookpot targeted completes", State(filter_player) == "won")
end

type_fixtures.prototype = function()
    local fixture_manager, player = Spawn(function(target)
        target.components.builder = { recipes = { "goldenaxe" } }
    end)
    Activate(fixture_manager, player, {
        id = "fixture_prototype",
        title = "Eureka",
        subtext = "Knowledge.",
        objectives = {
            { type = "prototype", count = 2, label = "Prototype new recipes" },
        },
    })
    Check("prototype label is rendered", Row(player, 1)[1] == "Prototype new recipes")
    Check("prototype default icon is blueprint", Row(player, 1)[2] == "blueprint")

    player:Fire("unlockrecipe")
    Check("data-less unlockrecipe is ignored", Row(player, 1)[3] == "0/2")
    player:Fire("unlockrecipe", { recipe = "goldenaxe" })
    Check("already-known recipe is ignored", Row(player, 1)[3] == "0/2")
    player:Fire("unlockrecipe", { recipe = "spear" })
    Check("new recipe counts", Row(player, 1)[3] == "1/2")
    player:Fire("unlockrecipe", { recipe = "spear" })
    Check("repeated unlock does not double count", Row(player, 1)[3] == "1/2")
    player:Fire("unlockrecipe", { recipe = "backpack" })
    Check("prototype completes at target", State(player) == "won")

    -- Optional prefab (a recipe id) targets one recipe.
    local filter_manager, filter_player = Spawn()
    Activate(filter_manager, filter_player, {
        id = "fixture_prototype_one",
        title = "Golden Idea",
        subtext = "Shiny.",
        objectives = {
            { type = "prototype", prefab = "goldenaxe", count = 1, label = "Prototype a Golden Axe" },
        },
    })
    Check("targeted prototype label is rendered",
        Row(filter_player, 1)[1] == "Prototype a Golden Axe")
    Check("targeted prototype icon is the recipe id",
        Row(filter_player, 1)[2] == "goldenaxe")
    filter_player:Fire("unlockrecipe", { recipe = "spear" })
    Check("other recipes are filtered out", State(filter_player) == "active")
    filter_player:Fire("unlockrecipe", { recipe = "goldenaxe" })
    Check("targeted prototype completes", State(filter_player) == "won")
end

-- Every VALID_TYPE must have a fixture, and no fixture may outlive its type.
local type_names = {}
for objective_type in pairs(Objectives.VALID_TYPES) do
    type_names[#type_names + 1] = objective_type
end
table.sort(type_names)

for _, objective_type in ipairs(type_names) do
    local fixture = type_fixtures[objective_type]
    Check("harness has a fixture for objective type " .. objective_type, fixture ~= nil)
    if fixture ~= nil then
        fixture()
    end
end
for objective_type in pairs(type_fixtures) do
    Check("fixture type " .. objective_type .. " is still a known type",
        Objectives.VALID_TYPES[objective_type] == true)
end

-- ---- real mission render smoke ------------------------------------------
--
-- Activate every mission in the real chain and check it renders one well-formed
-- row per objective. This catches label/icon/counter crashes in mission data
-- without pinning any content: titles, counts, order and wording may change
-- freely.

for i, mission in ipairs(RealMissions) do
    local smoke_manager, player = Spawn()
    smoke_manager.current_mission = mission
    smoke_manager.completed = false
    smoke_manager.progress = {}
    for j, objective in ipairs(mission.objectives or {}) do
        smoke_manager.progress[j] = Objectives.InitialProgress(player, objective)
    end
    smoke_manager:Sync()

    local label = string.format("real mission %d (%s) renders", i, tostring(mission.id))
    local rows = Rows(Read(player)["guidedmissions.rows"])
    Check(label .. " one row per objective", #rows == #(mission.objectives or {}))

    local well_formed = true
    for _, fields in ipairs(rows) do
        if fields[1] == nil or fields[1] == ""
            or fields[3] == nil or fields[3] == ""
            or fields[4] == nil then
            well_formed = false
        end
    end
    Check(label .. " every row has a label, counter and done flag", well_formed)
end

print(failures == 0 and "ALL PASS" or ("FAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
