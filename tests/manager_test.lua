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
local RealEmergencies = require("guidedmissions/emergencies")
local Strings = require("guidedmissions/strings")
local L10n = require("guidedmissions/l10n")
-- The manager and this harness share the same settings table instance.
local Settings = require("guidedmissions/settings")

local failures = 0

local function Check(label, cond)
    if cond then
        print("PASS  " .. label)
    else
        failures = failures + 1
        print("FAIL  " .. label)
    end
end

-- Split the packed row string into
-- `{ label, prefab, counter, done, optional }` tables.
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
-- one (a recipe id), `plant` takes one (a seed filter), `trap_catch` takes one
-- (a loot filter), `sleep` takes one (a bed filter) and `fertilize` takes one
-- (a plant filter); every other type either ignores the field or does not have
-- one.
local optional_prefab = {
    cook = true, cookpot = true, prototype = true, plant = true, trap_catch = true,
    sleep = true, fertilize = true,
}

-- Shared by chain and emergency validation. Returns `optional == true` so the
-- mission loop can count rows that gate completion.
local function ValidateObjectiveFields(where, objective, index)
    local row = string.format("%s objective %d (%s)", where, index, tostring(objective.type))
    Check(row .. " uses a known type", Objectives.VALID_TYPES[objective.type] == true)
    Check(row .. " optional flag is a boolean",
        objective.optional == nil or type(objective.optional) == "boolean")

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
    elseif objective.type == "reach_stat" then
        -- A live stat row has no count: it tracks a percentage against a
        -- threshold string on the same 0-100 scale as emergency conditions.
        Check(row .. " names a known stat",
            RealEmergencies.VALID_STATS[objective.stat] == true)
        local operator = RealEmergencies.ParseThreshold(objective.threshold)
        Check(row .. " threshold parses", operator ~= nil)
    else
        Check(row .. " has a count", tonumber(objective.count) ~= nil)
    end

    return objective.optional == true
end

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
    Check(where .. " hint is text when set",
        mission.hint == nil or (type(mission.hint) == "string" and #mission.hint > 0))
    Check(where .. " has an objective list",
        type(mission.objectives) == "table" and #mission.objectives > 0)

    -- A mission whose objectives are all optional would complete the instant it
    -- starts, so require at least one objective that gates completion.
    local required_count = 0
    for j, objective in ipairs(mission.objectives or {}) do
        if not ValidateObjectiveFields(where, objective, j) then
            required_count = required_count + 1
        end
    end

    Check(where .. " has at least one required objective", required_count > 0)
end

-- Emergency data sanity, against the real emergencies.lua. The manager treats
-- these entries as mission-shaped, so they get the same objective rules plus a
-- strict trigger/resolve schema.
local emergency_ids = {}
for i, entry in ipairs(RealEmergencies.entries) do
    local where = string.format("emergency %d (%s)", i, tostring(entry.id))

    Check(where .. " has a unique id",
        IsPrefabId(entry.id) and emergency_ids[entry.id] == nil)
    if type(entry.id) == "string" then
        emergency_ids[entry.id] = true
    end
    Check(where .. " has a title",
        type(entry.title) == "string" and #entry.title > 0)
    Check(where .. " has a subtext",
        type(entry.subtext) == "string" and #entry.subtext > 0)
    Check(where .. " resolved_subtext is text when set",
        entry.resolved_subtext == nil
            or (type(entry.resolved_subtext) == "string" and #entry.resolved_subtext > 0))
    Check(where .. " hint is text when set",
        entry.hint == nil or (type(entry.hint) == "string" and #entry.hint > 0))

    local function ValidateCondition(name, condition, want_low)
        Check(where .. " " .. name .. " is a table", type(condition) == "table")
        if type(condition) ~= "table" then
            return nil
        end
        Check(where .. " " .. name .. " kind is known",
            RealEmergencies.VALID_KINDS[condition.kind] == true)
        Check(where .. " " .. name .. " stat is known",
            RealEmergencies.VALID_STATS[condition.stat] == true)

        local operator, value = RealEmergencies.ParseThreshold(condition.threshold)
        Check(where .. " " .. name .. " threshold parses", operator ~= nil)
        if operator ~= nil then
            local is_low = operator == "<" or operator == "<="
            Check(where .. " " .. name .. " uses a "
                .. (want_low and "low" or "high") .. " comparison", is_low == want_low)
        end
        return value
    end

    local trigger_value = ValidateCondition("trigger", entry.trigger, true)
    local resolve_value = ValidateCondition("resolve", entry.resolve, false)
    Check(where .. " trigger and resolve use the same stat",
        type(entry.trigger) == "table" and type(entry.resolve) == "table"
            and entry.trigger.stat == entry.resolve.stat)
    if trigger_value ~= nil and resolve_value ~= nil then
        Check(where .. " resolve is at or above the trigger",
            resolve_value >= trigger_value)
    end

    Check(where .. " has an objective list",
        type(entry.objectives) == "table" and #entry.objectives > 0)

    -- Exactly one required row: the recovery goal. It must match `resolve`, so
    -- the card cannot promise a threshold different from the one that ends the
    -- emergency. Every other row is optional guidance.
    local required_count = 0
    for j, objective in ipairs(entry.objectives or {}) do
        if not ValidateObjectiveFields(where, objective, j) then
            required_count = required_count + 1
            Check(where .. " goal row is reach_stat",
                objective.type == "reach_stat")
            Check(where .. " goal stat matches resolve",
                type(entry.resolve) == "table"
                    and objective.stat == entry.resolve.stat)
            Check(where .. " goal threshold matches resolve",
                type(entry.resolve) == "table"
                    and objective.threshold == entry.resolve.threshold)
        end
    end
    Check(where .. " has exactly one required goal row", required_count == 1)
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
        hint = "First synthetic hint.",
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

-- Emergencies bind at require time too. Keep the real helpers (the schema and
-- stat reads are what the behavioural tests exercise) and swap only the
-- entries, so content edits cannot break the mechanics tests.
local SyntheticEmergencies = {
    {
        id = "harness_emergency_health",
        title = "Harness Emergency Health",
        subtext = "Hurt.",
        resolved_subtext = "Recovered.",
        hint = "Harness emergency hint.",
        trigger = { kind = "stat", stat = "health", threshold = "<50" },
        resolve = { kind = "stat", stat = "health", threshold = ">=70" },
        objectives = {
            { type = "reach_stat", stat = "health", threshold = ">=70",
              label = "Get back to 70% health" },
            { type = "heal", count = 10, label = "Restore health", optional = true },
            { type = "collect", prefab = "log", count = 2,
              label = "Hold logs", optional = true },
        },
    },
    {
        id = "harness_emergency_sanity",
        title = "Harness Emergency Sanity",
        subtext = "Fraying.",
        resolved_subtext = "Steady.",
        trigger = { kind = "stat", stat = "sanity", threshold = "<50" },
        resolve = { kind = "stat", stat = "sanity", threshold = ">=75" },
        objectives = {
            { type = "reach_stat", stat = "sanity", threshold = ">=75",
              label = "Get back to 75% sanity" },
            { type = "sanity", count = 10, label = "Restore sanity", optional = true },
        },
    },
}
package.loaded["guidedmissions/emergencies"] = {
    entries = SyntheticEmergencies,
    VALID_STATS = RealEmergencies.VALID_STATS,
    VALID_KINDS = RealEmergencies.VALID_KINDS,
    GetStatFraction = RealEmergencies.GetStatFraction,
    ParseThreshold = RealEmergencies.ParseThreshold,
    IsTriggered = RealEmergencies.IsTriggered,
    IsResolved = RealEmergencies.IsResolved,
}

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
Check("startup hint", state["guidedmissions.hint"] == "First synthetic hint.")
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
Check("won card drops the hint", Read()["guidedmissions.hint"] == "")
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
Check("mission without a hint clears it", Read()["guidedmissions.hint"] == "")
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

-- 5b. Optional objectives are tracked and flagged, but never gate completion,
-- and an unfinished optional row keeps its real (unchecked) state on the won
-- card instead of being forced done by the hold.
local opt_manager, opt_player = Spawn()
Activate(opt_manager, opt_player, {
    id = "harness_optional",
    title = "Harness Optional",
    subtext = "One required, one optional.",
    objectives = {
        { type = "collect", prefab = "flint", count = 1, label = "Required flint" },
        { type = "collect", prefab = "log", count = 5, label = "Optional logs", optional = true },
    },
})
Check("required row is not marked optional", Row(opt_player, 1)[5] == "0")
Check("optional row is marked", Row(opt_player, 2)[5] == "1")

-- Authoring order does not matter: required rows are always emitted first so
-- the HUD can draw one "Optional" heading above the group.
local group_manager, group_player = Spawn()
Activate(group_manager, group_player, {
    id = "harness_optional_order",
    title = "Harness Order",
    subtext = "Optional authored first.",
    objectives = {
        { type = "collect", prefab = "log", count = 5, label = "Optional logs", optional = true },
        { type = "collect", prefab = "flint", count = 1, label = "Required flint" },
    },
})
Check("required row renders first", Row(group_player, 1)[1] == "Required flint")
Check("optional row renders second", Row(group_player, 2)[1] == "Optional logs")
Check("grouped optional row keeps its flag", Row(group_player, 2)[5] == "1")
Carry(group_player, "flint", 1)
InventoryChanged(group_player)
Check("grouped row keeps its progress", Row(group_player, 1)[3] == "1/1")

-- Optional progress counts as normal while the mission is active.
Carry(opt_player, "log", 5)
InventoryChanged(opt_player)
Check("optional progress counts", Row(opt_player, 2)[3] == "5/5")
Check("optional alone does not finish the mission", State(opt_player) == "active")

-- Finish only the required objective on a fresh fixture.
local gate_manager, gate_player = Spawn()
Activate(gate_manager, gate_player, {
    id = "harness_gate",
    title = "Harness Gate",
    subtext = "Optional unfinished.",
    objectives = {
        { type = "collect", prefab = "flint", count = 1, label = "Required flint" },
        { type = "collect", prefab = "log", count = 5, label = "Optional logs", optional = true },
    },
})
Carry(gate_player, "flint", 1)
InventoryChanged(gate_player)
Check("required objective completes the mission", State(gate_player) == "won")
Check("won card checks the required row", Row(gate_player, 1)[4] == "1")
Check("won card leaves the optional row unchecked", Row(gate_player, 2)[4] == "0")
Check("won card still flags the optional row", Row(gate_player, 2)[5] == "1")

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

-- ---- emergency overlay ----------------------------------------------------
--
-- Emergencies trigger from health/sanity events and the poll, replace the
-- chain card, and restore the chain untouched. These use the synthetic entries
-- swapped in before the manager was required.

Settings.emergency_frequency = "session"

local function SetHealth(player, current, max)
    player.components.health = { currenthealth = current, maxhealth = max or 100 }
end

local function SetSanity(player, current, max)
    player.components.sanity = { current = current, max = max or 100 }
end

-- Threshold syntax is explicit about inclusivity.
local function Parses(text, operator, value)
    local op, val = RealEmergencies.ParseThreshold(text)
    return op == operator and val == value
end
Check("threshold <50 parses", Parses("<50", "<", 50))
Check("threshold <=50 parses", Parses("<=50", "<=", 50))
Check("threshold >50 parses", Parses(">50", ">", 50))
Check("threshold >=50 parses", Parses(">=50", ">=", 50))
Check("threshold tolerates whitespace", Parses("  >= 75 ", ">=", 75))
Check("threshold parses a decimal", Parses("<12.5", "<", 12.5))
Check("threshold rejects a missing operator",
    RealEmergencies.ParseThreshold("50") == nil)
Check("threshold rejects a reversed operator",
    RealEmergencies.ParseThreshold("=<50") == nil)
Check("threshold rejects values outside 0-100",
    RealEmergencies.ParseThreshold("<101") == nil
        and RealEmergencies.ParseThreshold(">-1") == nil)

-- Stat reads use raw fields, not GetPercent (which sanity masks).
local stat_player = NewInst(3001)
SetHealth(stat_player, 40, 100)
Check("health fraction uses current/max",
    math.abs(RealEmergencies.GetStatFraction(stat_player, "health") - 0.4) < 0.0001)
SetSanity(stat_player, 25, 50)
Check("sanity fraction uses current/max",
    math.abs(RealEmergencies.GetStatFraction(stat_player, "sanity") - 0.5) < 0.0001)
Check("missing stat fraction is nil",
    RealEmergencies.GetStatFraction(NewInst(3002), "health") == nil)
Check("unknown stat fraction is nil",
    RealEmergencies.GetStatFraction(stat_player, "hunger") == nil)

-- Operator boundaries: < excludes, <= includes, >= includes.
local inclusive_entry = {
    trigger = { kind = "stat", stat = "health", threshold = "<=50" },
}
local boundary_player = NewInst(3003)
SetHealth(boundary_player, 50, 100)
Check("<= includes the boundary",
    RealEmergencies.IsTriggered(inclusive_entry, boundary_player))
local resolve_entry = {
    resolve = { kind = "stat", stat = "health", threshold = ">=75" },
}
SetHealth(boundary_player, 75, 100)
Check(">= includes the boundary",
    RealEmergencies.IsResolved(resolve_entry, boundary_player))
SetHealth(boundary_player, 74, 100)
Check(">= excludes below the boundary",
    not RealEmergencies.IsResolved(resolve_entry, boundary_player))

-- Trigger on a stat event, with partial chain progress to preserve.
local em_manager, em_player = Spawn()
Carry(em_player, "flint", 1)
InventoryChanged(em_player)
Check("chain progress before the emergency", Row(em_player, 1)[3] == "1/3")

SetHealth(em_player, 40, 100)
em_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("emergency pops on a health event",
    Read(em_player)["guidedmissions.title"] == "Harness Emergency Health")
Check("emergency state", State(em_player) == "emergency")
Check("emergency card shows its hint",
    Read(em_player)["guidedmissions.hint"] == "Harness emergency hint.")
Check("chain mission is suspended",
    em_manager.suspended_mission == SyntheticMissions[1])
Check("chain index did not move", em_manager.mission_index == 1)
Check("emergency goal row renders first",
    Row(em_player, 1)[1] == "Get back to 70% health")
Check("emergency goal counter is live",
    Row(em_player, 1)[3] == "40/70%")
Check("emergency optional rows render",
    Row(em_player, 2)[1] == "Restore health"
        and Row(em_player, 3)[1] == "Hold logs")

-- Emergency objectives track but never complete the overlay or the chain.
em_player:Fire("healthdelta", { oldpercent = 0.4, newpercent = 0.45, amount = 5 })
Check("emergency objective tracks", Row(em_player, 2)[3] == "5/10")
Check("emergency does not complete on objectives", State(em_player) == "emergency")
Check("chain progress untouched during the emergency",
    em_manager.suspended_progress[1] == 1)

-- Resolve: recovered card, 3-second hold, then the chain returns intact.
SetHealth(em_player, 80, 100)
em_player:Fire("healthdelta", { oldpercent = 0.45, newpercent = 0.8, amount = 35 })
Check("resolved card state", State(em_player) == "won")
Check("resolved card title",
    Read(em_player)["guidedmissions.title"] == "Harness Emergency Health")
Check("resolved card subtext",
    Read(em_player)["guidedmissions.subtext"] == "Recovered.")
Check("resolved card drops the hint", Read(em_player)["guidedmissions.hint"] == "")
Check("recovered card shows the goal met", Row(em_player, 1)[4] == "1")
Check("emergency hold pending", em_manager.emergency_hold_task ~= nil)
Check("chain stays hidden during the recovery hold", em_manager.current_mission == nil)

Advance(3)
Check("chain restored after the hold",
    Read(em_player)["guidedmissions.title"] == "Harness First")
Check("chain state active after the hold", State(em_player) == "active")
Check("chain progress survived the emergency", Row(em_player, 1)[3] == "1/3")
Check("chain index still unchanged", em_manager.mission_index == 1)

-- Once per session: a fresh drop does not re-trigger.
SetHealth(em_player, 40, 100)
em_player:Fire("healthdelta", { oldpercent = 0.8, newpercent = 0.4, amount = -40 })
Check("no retrigger in the same session",
    Read(em_player)["guidedmissions.title"] == "Harness First")
Check("still active after the suppressed trigger", State(em_player) == "active")

-- Per-trigger: the sanity emergency can still fire once.
SetSanity(em_player, 40, 100)
em_player:Fire("sanitydelta", { oldpercent = 0.9, newpercent = 0.4 })
Check("sanity emergency triggers independently",
    Read(em_player)["guidedmissions.title"] == "Harness Emergency Sanity")
SetSanity(em_player, 80, 100)
em_player:Fire("sanitydelta", { oldpercent = 0.4, newpercent = 0.8 })
Check("sanity recovered card", State(em_player) == "won")
Advance(3)
Check("chain restored after the sanity emergency",
    Read(em_player)["guidedmissions.title"] == "Harness First")

-- Precise threshold: exactly 50% does not trigger "<50"; 49% does.
local exact_manager, exact_player = Spawn(function(target)
    target.components.health = { currenthealth = 50, maxhealth = 100 }
end)
Check("exact threshold does not trigger", State(exact_player) == "active")
local below_manager, below_player = Spawn(function(target)
    target.components.health = { currenthealth = 49, maxhealth = 100 }
end)
Check("below threshold triggers", State(below_player) == "emergency")

-- Missing components and ghosts never trigger.
local bare_manager, bare_player = Spawn()
Check("no stat components means no emergency", State(bare_player) == "active")
local ghost_manager, ghost_player = Spawn(function(target)
    target.components.health = {
        currenthealth = 0,
        maxhealth = 100,
        IsDead = function() return true end,
    }
end)
Check("no emergency while dead", State(ghost_player) == "active")

-- Begin triggers immediately for a player already below the threshold.
local begin_manager, begin_player = Spawn(function(target)
    target.components.health = { currenthealth = 30, maxhealth = 100 }
end)
Check("Begin triggers for a low-health player", State(begin_player) == "emergency")

-- "always" ignores the fired set; a fresh drop re-triggers.
Settings.emergency_frequency = "always"
local always_manager, always_player = Spawn()
SetHealth(always_player, 40, 100)
always_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("always mode triggers", State(always_player) == "emergency")
SetHealth(always_player, 80, 100)
always_player:Fire("healthdelta", { oldpercent = 0.4, newpercent = 0.8, amount = 40 })
Advance(3)
SetHealth(always_player, 40, 100)
always_player:Fire("healthdelta", { oldpercent = 0.8, newpercent = 0.4, amount = -40 })
Check("always mode re-triggers", State(always_player) == "emergency")
Settings.emergency_frequency = "session"

-- "server" persists the fired set in the save.
Settings.emergency_frequency = "server"
local server_manager, server_player = Spawn()
SetHealth(server_player, 40, 100)
server_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("server mode triggers", State(server_player) == "emergency")
local server_save = server_manager:OnSave()
Check("server mode saves the fired set",
    type(server_save.fired_emergencies) == "table"
        and server_save.fired_emergencies["harness_emergency_health"] == true)
Check("server save stores the chain mission",
    server_save.mission_id == "harness_first")
Check("server save stores the chain progress",
    server_save.progress[1] == 0)

local restored_inst = NewInst(4001)
SetHealth(restored_inst, 100, 100)
Netvars.Attach(restored_inst)
local restored_manager = Manager(restored_inst)
restored_manager:OnLoad(server_save)
Advance(1)
SetHealth(restored_inst, 40, 100)
restored_inst:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("server mode suppresses a saved trigger",
    Read(restored_inst)["guidedmissions.title"] == "Harness First")
Settings.emergency_frequency = "session"

-- A save during an emergency stores the chain, not the overlay.
local save_manager, save_player = Spawn()
Carry(save_player, "flint", 1)
InventoryChanged(save_player)
SetHealth(save_player, 40, 100)
save_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("save test emergency active", State(save_player) == "emergency")
local save_data = save_manager:OnSave()
Check("save mid-emergency stores the chain mission",
    save_data.mission_id == "harness_first")
Check("save mid-emergency stores chain progress", save_data.progress[1] == 1)
Check("save mid-emergency never stores an emergency id",
    save_data.mission_id ~= "harness_emergency_health")
Check("save mid-emergency omits a session fired set",
    save_data.fired_emergencies == nil)

local reload_inst = NewInst(4002)
SetHealth(reload_inst, 100, 100)
Netvars.Attach(reload_inst)
local reload_manager = Manager(reload_inst)
reload_manager:OnLoad(save_data)
Advance(1)
Check("load mid-emergency resumes the chain",
    Read(reload_inst)["guidedmissions.title"] == "Harness First")
Check("load mid-emergency restores progress", Row(reload_inst, 1)[3] == "1/3")
Check("load mid-emergency drops the overlay", reload_manager.emergency == nil)

-- An admin jump clears the overlay; Reset also re-arms emergencies.
local jump_manager, jump_player = Spawn()
SetHealth(jump_player, 40, 100)
jump_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("jump test emergency active", State(jump_player) == "emergency")
Check("jump accepted", jump_manager:JumpTo(2) == true)
Check("jump lands on mission 2",
    Read(jump_player)["guidedmissions.title"] == "Harness Second")
Check("jump clears the overlay", jump_manager.emergency == nil
    and jump_manager.suspended_mission == nil)

jump_manager.fired_emergencies["harness_emergency_health"] = true
jump_manager:JumpTo(2)
Check("a jump keeps the fired set",
    jump_manager.fired_emergencies["harness_emergency_health"] == true)
jump_manager:Reset()
Check("reset clears the fired set",
    next(jump_manager.fired_emergencies) == nil)

-- No trigger during the chain's won hold or after the chain is complete.
local hold_manager, hold_player = Spawn()
hold_manager.progress[1] = 3
hold_manager:CheckCompletion()
Check("chain hold active", State(hold_player) == "won")
SetHealth(hold_player, 40, 100)
hold_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("no emergency during the chain hold", State(hold_player) == "won")

local done_manager, done_player = Spawn()
done_manager:JumpTo(#SyntheticMissions + 1)
SetHealth(done_player, 40, 100)
done_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("no emergency after chain completion", State(done_player) == "done")
Advance(1)
Check("still no emergency after a poll", State(done_player) == "done")

-- Cleanup cancels the recovered-card hold as well.
local cleanup_manager, cleanup_player = Spawn()
SetHealth(cleanup_player, 40, 100)
cleanup_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
SetHealth(cleanup_player, 80, 100)
cleanup_player:Fire("healthdelta", { oldpercent = 0.4, newpercent = 0.8, amount = 40 })
Check("cleanup: recovered hold pending", cleanup_manager.emergency_hold_task ~= nil)
cleanup_manager:OnRemoveFromEntity()
local emergency_live_tasks = 0
for _, task in ipairs(tasks) do
    if task.owner == cleanup_player and not task.cancelled then
        emergency_live_tasks = emergency_live_tasks + 1
    end
end
Check("cleanup: all emergency tasks cancelled",
    cleanup_manager.emergency_hold_task == nil and emergency_live_tasks == 0)

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
    -- Fields 6-8 let each client format the day counter in its own language.
    Check("survive counter kind", Row(player, 1)[6] == "day")
    Check("survive counter current", Row(player, 1)[7] == "1")
    Check("survive counter target", Row(player, 1)[8] == "3")

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

type_fixtures.sleep = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_sleep",
        title = "Lights Out",
        subtext = "Rest.",
        objectives = {
            { type = "sleep", prefab = "tent", count = 1, label = "Sleep in a tent" },
        },
    })
    Check("sleep label is rendered", Row(player, 1)[1] == "Sleep in a tent")
    Check("sleep row is text-only", Row(player, 1)[2] == "")

    -- The event is pushed by modmain's sleepingbaguser hook; it carries the bed
    -- entity, so a prefab filter matches its prefab.
    player:Fire("guidedmissions_slept", { bed = { prefab = "siestahut" } })
    Check("sleeping in another bed does not count", State(player) == "active")
    player:Fire("guidedmissions_slept", { bed = { prefab = "tent" } })
    Check("sleeping in the target bed completes", State(player) == "won")

    -- Without a filter any sleeping bag counts: tent, siesta hut or bedroll.
    local any_manager, any_player = Spawn()
    Activate(any_manager, any_player, {
        id = "fixture_sleep_any",
        title = "Any Bed",
        subtext = "Any port in a storm.",
        objectives = {
            { type = "sleep", count = 2, label = "Sleep in a bed" },
        },
    })
    any_player:Fire("guidedmissions_slept", { bed = { prefab = "bedroll_straw" } })
    Check("unfiltered sleep counts a bedroll", Row(any_player, 1)[3] == "1/2")
    any_player:Fire("guidedmissions_slept", { bed = { prefab = "siestahut" } })
    Check("unfiltered sleep completes at the target", State(any_player) == "won")
end

type_fixtures.reach_stat = function()
    local fixture_manager, player = Spawn(function(target)
        -- 60 is above the harness emergency's "<50" trigger, so this fixture
        -- exercises the row without an emergency taking over the card.
        target.components.health = { currenthealth = 60, maxhealth = 100 }
    end)
    Activate(fixture_manager, player, {
        id = "fixture_reach_stat",
        title = "Recover",
        subtext = "Get back up.",
        objectives = {
            { type = "reach_stat", stat = "health", threshold = ">=75",
              label = "Get back to 75% health" },
        },
    })
    Check("reach_stat label is rendered", Row(player, 1)[1] == "Get back to 75% health")
    Check("reach_stat icon is the heart", Row(player, 1)[2] == "heart")
    Check("reach_stat counter shows current/target", Row(player, 1)[3] == "60/75%")
    Check("reach_stat is incomplete at 60%", State(player) == "active")

    -- It mirrors the live stat (it may fall), refreshed by the poll.
    player.components.health.currenthealth = 50
    Advance(1)
    Check("reach_stat follows a drop", Row(player, 1)[3] == "50/75%")
    player.components.health.currenthealth = 80
    Advance(1)
    Check("reach_stat completes at the threshold", State(player) == "won")
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
            { type = "plant", count = 2, label = "Plant something" },
        },
    })
    Check("plant label is rendered", Row(player, 1)[1] == "Plant something")
    Check("plant default icon is the generic seed", Row(player, 1)[2] == "seeds")

    player:Fire("guidedmissions_planted")
    Check("data-less planted event is ignored", Row(player, 1)[3] == "0/2")
    player:Fire("guidedmissions_planted", { item = "carrot_seeds" })
    Check("planting any seed counts", Row(player, 1)[3] == "1/2")
    -- Dug plants deploy through a different engine path but are the same
    -- intent, so they feed the same objective (the held item, not the plant).
    player:Fire("guidedmissions_planted", { item = "dug_berrybush" })
    Check("replanting a dug bush completes", State(player) == "won")

    -- Optional prefab filters on the item the player planted: a seed id for
    -- tilled soil, a `dug_` id for a deploy.
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
    filter_player:Fire("guidedmissions_planted", { item = "pumpkin_seeds" })
    Check("other seeds are filtered out", State(filter_player) == "active")
    filter_player:Fire("guidedmissions_planted", { item = "carrot_seeds" })
    Check("targeted plant completes", State(filter_player) == "won")

    -- A dug plant filter names the dug item, not the bush it becomes.
    local dug_manager, dug_player = Spawn()
    Activate(dug_manager, dug_player, {
        id = "fixture_plant_dug",
        title = "Relocation",
        subtext = "Bushes travel well.",
        objectives = {
            { type = "plant", prefab = "dug_berrybush", count = 1, label = "Replant a berry bush" },
        },
    })
    dug_player:Fire("guidedmissions_planted", { item = "dug_sapling" })
    Check("another dug plant is filtered out", State(dug_player) == "active")
    dug_player:Fire("guidedmissions_planted", { item = "dug_berrybush" })
    Check("the filtered dug plant completes", State(dug_player) == "won")
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

type_fixtures.trap_catch = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_trap_catch",
        title = "Trap Line",
        subtext = "Check your traps.",
        objectives = {
            { type = "trap_catch", count = 2, label = "Check traps with a catch" },
        },
    })
    Check("trap_catch label is rendered", Row(player, 1)[1] == "Check traps with a catch")
    Check("trap_catch default icon is the trap", Row(player, 1)[2] == "trap")
    Check("trap_catch starts at 0/2", Row(player, 1)[3] == "0/2")

    -- The event only comes from modmain's trap hook. An unfiltered objective
    -- does not care what the trap holds.
    player:Fire("guidedmissions_trapchecked", { loot = { "silk" } })
    Check("trap_catch counts a catch", Row(player, 1)[3] == "1/2")
    player:Fire("guidedmissions_trapchecked", { loot = { "rabbit" } })
    Check("trap_catch completes at target", State(player) == "won")

    -- A prefab filter matches an entry in the trap's loot list. A rabbit trap
    -- stores the rabbit itself, so creature filters work there.
    local filter_manager, filter_player = Spawn()
    Activate(filter_manager, filter_player, {
        id = "fixture_trap_catch_one",
        title = "Rabbit Line",
        subtext = "Just rabbits.",
        objectives = {
            { type = "trap_catch", prefab = "rabbit", count = 1, label = "Catch a rabbit" },
        },
    })
    Check("filtered trap_catch icon is the prefab", Row(filter_player, 1)[2] == "rabbit")
    filter_player:Fire("guidedmissions_trapchecked", { loot = { "froglegs" } })
    Check("other loot is filtered out", State(filter_player) == "active")
    filter_player:Fire("guidedmissions_trapchecked", { loot = { "rabbit" } })
    Check("matching loot completes", State(filter_player) == "won")

    -- A lootdropper catch stores its drops, so multi-item loot can match any
    -- entry: a spider trap might hold silk among other drops.
    local loot_manager, loot_player = Spawn()
    Activate(loot_manager, loot_player, {
        id = "fixture_trap_catch_loot",
        title = "Silk Line",
        subtext = "Look for silk.",
        objectives = {
            { type = "trap_catch", prefab = "silk", count = 1, label = "Catch something silky" },
        },
    })
    loot_player:Fire("guidedmissions_trapchecked",
        { loot = { "monstermeat", "spidergland", "silk" } })
    Check("any matching loot entry counts", State(loot_player) == "won")
end

type_fixtures.fertilize = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_fertilize",
        title = "Green Thumb",
        subtext = "Feed the plants.",
        objectives = {
            { type = "fertilize", count = 2, label = "Fertilize plants" },
        },
    })
    Check("fertilize label is rendered", Row(player, 1)[1] == "Fertilize plants")
    Check("fertilize default icon is rot", Row(player, 1)[2] == "rot")
    Check("fertilize starts at 0/2", Row(player, 1)[3] == "0/2")

    -- The event only comes from modmain's pickable hook. An unfiltered row
    -- counts any fertilizer on any plant.
    player:Fire("guidedmissions_fertilized", { plant = { prefab = "grass" } })
    Check("fertilize counts a plant", Row(player, 1)[3] == "1/2")
    player:Fire("guidedmissions_fertilized", { plant = { prefab = "berrybush" } })
    Check("fertilize completes at target", State(player) == "won")

    -- A prefab filter matches the fertilized plant, not the fertilizer.
    local filter_manager, filter_player = Spawn()
    Activate(filter_manager, filter_player, {
        id = "fixture_fertilize_one",
        title = "Bush Feed",
        subtext = "Just the bushes.",
        objectives = {
            { type = "fertilize", prefab = "berrybush", count = 1,
              label = "Fertilize a berry bush" },
        },
    })
    Check("filtered fertilize icon is the plant", Row(filter_player, 1)[2] == "berrybush")
    filter_player:Fire("guidedmissions_fertilized",
        { plant = { prefab = "berrybush_juicy" } })
    Check("another plant is filtered out", State(filter_player) == "active")
    filter_player:Fire("guidedmissions_fertilized", { plant = { prefab = "berrybush" } })
    Check("the filtered plant completes", State(filter_player) == "won")

    -- An explicit icon wins over the plant's (plants have no inventory art).
    local icon_manager, icon_player = Spawn()
    Activate(icon_manager, icon_player, {
        id = "fixture_fertilize_icon",
        title = "Berries",
        subtext = "Bush duty.",
        objectives = {
            { type = "fertilize", prefab = "berrybush", count = 1,
              icon = "berries", label = "Fertilize a berry bush" },
        },
    })
    Check("fertilize icon override wins", Row(icon_player, 1)[2] == "berries")
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

-- ---- real emergency render smoke ----------------------------------------
--
-- Same contract as the mission smoke, using the real emergency entries.

for i, entry in ipairs(RealEmergencies.entries) do
    local smoke_manager, player = Spawn()
    Check("real emergency " .. i .. " activates",
        smoke_manager:ActivateEmergency(entry) == true)

    local label = string.format("real emergency %d (%s) renders", i, tostring(entry.id))
    Check(label .. " state", State(player) == "emergency")
    Check(label .. " title", Read(player)["guidedmissions.title"] == entry.title)

    local rows = Rows(Read(player)["guidedmissions.rows"])
    Check(label .. " one row per objective", #rows == #(entry.objectives or {}))

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

-- ---- translated server smoke ---------------------------------------------
--
-- Netvars always carry source text (each client translates its own copy); the
-- server translates only its own chat/log lines. Force a pseudo locale and
-- check both sides, including that a title is translated exactly once.

local pseudo = {}
for key in pairs(require("guidedmissions/languages/en")) do
    pseudo[key] = "XX " .. key
end
pseudo[Strings.MISSION_COMPLETE_FMT] = "XX %s completed: %s"
pseudo["Harness Twist"] = "XX Harness Twist"
L10n.RegisterLocale("xx", pseudo, 10)
L10n.SetLocale("xx")

local tr_manager, tr_player = Spawn()
Activate(tr_manager, tr_player, {
    id = "fixture_translated",
    title = "Harness Twist",
    subtext = "Twisted source.",
    objectives = {
        { type = "collect", prefab = "flint", count = 1, label = "Collect flint" },
    },
})
Check("translated smoke: title netvar stays source",
    Read(tr_player)["guidedmissions.title"] == "Harness Twist")
Check("translated smoke: subtext netvar stays source",
    Read(tr_player)["guidedmissions.subtext"] == "Twisted source.")
Check("translated smoke: row label stays source",
    Row(tr_player, 1)[1] == "Collect flint")

Carry(tr_player, "flint", 1)
InventoryChanged(tr_player)
Check("translated smoke: completion announcement uses server locale",
    announcements[#announcements] == "XX Wilson completed: XX Harness Twist")

L10n.SetLocale(nil)

print(failures == 0 and "ALL PASS" or ("FAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
