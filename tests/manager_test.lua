-- Server-side logic harness for the guided mission manager.
--
-- Runs the real manager/netvars/objectives/missions modules against a stubbed
-- DST environment and replays the whole chain: startup, partial progress, the
-- 3-second completion hold, the terminal `done` payload, save/load, and task
-- cleanup. This is plain Lua 5.1 — no game and no DST scripts are loaded.
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

function net_string(guid, name, event)
    local store = netvars_by_inst[guid]
    if store == nil then
        store = {}
        netvars_by_inst[guid] = store
    end
    local netvar = {}
    function netvar:set(value) store[name] = value end
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
        -- Items the player carries. Collect objectives are derived from this,
        -- not from events (see objectives.lua ReconcileProgress).
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

local inst = NewInst(1234)

local function Read(target)
    return netvars_by_inst[(target or inst).GUID] or {}
end

-- ---- harness -------------------------------------------------------------

local Netvars = require("guidedmissions/netvars")
local Manager = require("guidedmissions/manager")
local Missions = require("guidedmissions/missions")
local Objectives = require("guidedmissions/objectives")

Netvars.Attach(inst)
local manager = Manager(inst)

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

-- Add a stack of `prefab` to the player's inventory. The collect poller reads
-- this, which is how real pickups register (events do not carry them).
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

-- Felled-tree targets for chop objectives: `HasTag` plus a workable component.
-- Defined here because the walkthrough below replays the real mission chain.
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
-- error anywhere. This runs first because a bad type also derails the
-- walkthrough below (it drifts off the chain and can crash), which would bury
-- the real cause. Ids must be unique because saved progress is keyed by id,
-- not index.
--
-- The harness cannot know which prefabs the installed game ships (that needs
-- the game scripts), so this checks shape only: prefab, icon and recipe ids
-- are lowercase ids (`log`, `cookedmeat`, `berries_juicy`).
local function IsPrefabId(value)
    return type(value) == "string" and value:find("^[a-z0-9_]+$") ~= nil
end

local needs_prefab = {
    collect = true, craft = true, build = true, kill = true, eat = true, pick = true,
}
-- `cook`/`cookpot` take an optional prefab (a dish filter); every other type
-- either ignores the field or does not have one.
local optional_prefab = { cook = true, cookpot = true }

local seen_ids = {}
for i, mission in ipairs(Missions) do
    local where = string.format("mission %d (%s)", i, tostring(mission.id))
    local id = mission.id
    Check(where .. " has a unique id",
        IsPrefabId(id) and seen_ids[id] == nil)
    if type(id) == "string" then
        seen_ids[id] = true
    end
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

        if objective.icon ~= nil then
            Check(row .. " icon is a prefab id", IsPrefabId(objective.icon))
        end
        if objective.recipe ~= nil then
            Check(row .. " recipe is a recipe id", IsPrefabId(objective.recipe))
        end

        if objective.type == "survive" then
            Check(row .. " has a day", tonumber(objective.day) ~= nil)
        else
            Check(row .. " has a count", tonumber(objective.count) ~= nil)
        end
    end
end

-- Bad mission data also derails the walkthrough (the player drifts off the
-- chain and later sections index missing rows), so report the data problem and
-- stop rather than bury it in a cascade of downstream failures.
if failures > 0 then
    print("FAILURES: " .. failures .. " in mission data; walkthrough skipped")
    os.exit(1)
end

-- 1. startup: the first mission is active with its three rows, all at zero.
Advance(1)
local state = Read()
Check("startup state active", state["guidedmissions.state"] == "active")
Check("startup title", state["guidedmissions.title"] == "Basic Supplies")
Check("startup subtext", state["guidedmissions.subtext"] == "All great stories start somewhere.")
Check("startup rows count 3", #Rows(state["guidedmissions.rows"]) == 3)
Check("startup row1 label", Rows(state["guidedmissions.rows"])[1][1] == "Collect flint")
Check("startup row1 prefab", Rows(state["guidedmissions.rows"])[1][2] == "flint")
Check("startup row1 counter", Rows(state["guidedmissions.rows"])[1][3] == "0/3")
Check("startup row2 counter", Rows(state["guidedmissions.rows"])[2][3] == "0/10")
Check("startup row3 counter", Rows(state["guidedmissions.rows"])[3][3] == "0/10")
Check("mission start not announced in chat", #announcements == 0)

-- 2. Partial progress ticks without completing. Collect progress is read from
-- the inventory on the poll; events never add to it.
Carry(inst, "flint", 2)
Advance(1)
state = Read()
Check("partial counter 2/3", Rows(state["guidedmissions.rows"])[1][3] == "2/3")
Check("still active", state["guidedmissions.state"] == "active")

-- 3. One objective short of its target keeps the whole mission active.
Carry(inst, "flint", 1)
Carry(inst, "twigs", 10)
Carry(inst, "cutgrass", 9)
Advance(1)
state = Read()
Check("flint row done", Rows(state["guidedmissions.rows"])[1][4] == "1")
Check("short row counter 9/10", Rows(state["guidedmissions.rows"])[3][3] == "9/10")
Check("one short stays active", state["guidedmissions.state"] == "active")

-- 4. Completion writes the `won` payload with every row forced done.
Carry(inst, "cutgrass", 1)
Advance(1)
state = Read()
Check("mission1 won", state["guidedmissions.state"] == "won")
Check("won row1 done", Rows(state["guidedmissions.rows"])[1][4] == "1")
Check("won row3 done", Rows(state["guidedmissions.rows"])[3][4] == "1")
Check("won row1 counter full", Rows(state["guidedmissions.rows"])[1][3] == "3/3")
Check("completion announced in chat",
    announcements[#announcements] == "Wilson completed: Basic Supplies")

-- Progress during the hold is ignored: there is no current mission, so even
-- the inventory poll has nothing to update.
Carry(inst, "twigs", 5)
Advance(1)
Check("hold still won", Read()["guidedmissions.state"] == "won")

-- 5. After the hold the next mission starts, quietly.
local announce_count = #announcements
Advance(3)
state = Read()
Check("mission2 active", state["guidedmissions.state"] == "active")
Check("mission2 title", state["guidedmissions.title"] == "Tools of the Trade")
Check("mission2 rows count 2", #Rows(state["guidedmissions.rows"]) == 2)
Check("mission start not announced in chat", #announcements == announce_count)

local function Complete(label)
    Check(label .. " won", Read()["guidedmissions.state"] == "won")
    Advance(3)
end

-- 6. Tools of the Trade: axes and pickaxes are inventory items, so only
-- `builditem` counts; placing a structure is a different event entirely.
Check("craft row1 label", Rows(Read()["guidedmissions.rows"])[1][1] == "Craft an axe")
inst:Fire("buildstructure", Build("axe"))
Check("craft ignores buildstructure", Read()["guidedmissions.state"] == "active")
inst:Fire("builditem", Build("axe"))
Check("one of two recipes stays active", Read()["guidedmissions.state"] == "active")
inst:Fire("builditem", Build("pickaxe"))
Complete("mission2")

-- 7. Wood you Believe It?: `chop` counts felled trees only, and the log row is
-- inventory-derived, so neither completes the mission on its own.
state = Read()
Check("mission3 title", state["guidedmissions.title"] == "Wood you Believe It?")
Check("mission3 rows count 2", #Rows(state["guidedmissions.rows"]) == 2)
inst:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 3) })
Check("partial chop does not count", Rows(Read()["guidedmissions.rows"])[1][3] == "0/3")
inst:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
Check("felled tree counts", Rows(Read()["guidedmissions.rows"])[1][3] == "1/3")
Carry(inst, "log", 10)
Advance(1)
Check("logs row full, trees still short", Read()["guidedmissions.state"] == "active")
inst:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
inst:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
Complete("mission3")

-- 8. Let There Be Light: crafting the torch does not advance the world day.
state = Read()
Check("mission4 title", state["guidedmissions.title"] == "Let There Be Light")
Check("mission4 survive counter", Rows(state["guidedmissions.rows"])[2][3] == "Day 1/2")
Check("mission4 survive icon empty", Rows(state["guidedmissions.rows"])[2][2] == "")
inst:Fire("builditem", Build("torch"))
Check("torch row done, night still ahead", Read()["guidedmissions.state"] == "active")
-- The poll sees cycles = 1 as day 2.
TheWorld.state.cycles = 1
Advance(1)
Check("mission4 counter day 2", Rows(Read()["guidedmissions.rows"])[2][3] == "Day 2/2")
Complete("mission4")

-- 9. Food for Thought: `collect_food` is inventory-derived and counts any
-- edible item; `cook` counts successful fire cooking reported by modmain.
state = Read()
Check("mission5 title", state["guidedmissions.title"] == "Food for Thought")
Check("mission5 rows count 2", #Rows(state["guidedmissions.rows"]) == 2)
Check("collect_food row has a label",
    #Rows(state["guidedmissions.rows"])[1][1] > 0)
Check("collect_food row counter", Rows(state["guidedmissions.rows"])[1][3] == "0/5")
Check("cook row has a label", #Rows(state["guidedmissions.rows"])[2][1] > 0)
Check("cook row counter", Rows(state["guidedmissions.rows"])[2][3] == "0/2")

CarryFood(inst, "carrot", 3, "VEGGIE")
Advance(1)
Check("three carried foods count", Rows(Read()["guidedmissions.rows"])[1][3] == "3/5")

inst:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedmeat" } })
Check("one cook counts", Rows(Read()["guidedmissions.rows"])[2][3] == "1/2")
inst:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedmeat" } })
Check("cooking twice still waits on food", Read()["guidedmissions.state"] == "active")

CarryFood(inst, "berries", 2, "VEGGIE", "BERRY")
Advance(1)
Check("five carried foods complete the mission", Read()["guidedmissions.state"] == "won")
Advance(3)

-- 10. An Apple a Day: eating the wing is one row, restored health the other.
state = Read()
Check("mission6 title", state["guidedmissions.title"] == "An Apple a Day...")
inst.components.health = { maxhealth = 100 }
inst:Fire("oneat", { food = { prefab = "butterflywings" } })
Check("eat row done", Rows(Read()["guidedmissions.rows"])[1][4] == "1")
Check("eating a wing is not health", Read()["guidedmissions.state"] == "active")
inst:Fire("healthdelta", { oldpercent = 0.50, newpercent = 0.56, amount = 6 })
Check("heal counts restored points",
    Rows(Read()["guidedmissions.rows"])[2][3] == "6/10")
inst:Fire("healthdelta", { oldpercent = 0.94, newpercent = 1.00, amount = 20 })
Complete("mission6")

-- 11. Keeping Your Sanity: `pick` matches the picked plant's prefab, and
-- `sanity` credits points restored from any source.
state = Read()
Check("mission7 title", state["guidedmissions.title"] == "Keeping Your Sanity")
Check("pick row uses the flower icon", Rows(state["guidedmissions.rows"])[1][2] == "flower")
Check("sanity row uses the brain icon", Rows(state["guidedmissions.rows"])[2][2] == "brain")
inst:Fire("picksomething", { object = { prefab = "flower" } })
inst:Fire("picksomething", { object = { prefab = "flower" } })
inst:Fire("picksomething", { object = { prefab = "berrybush" } })
Check("other plants ignored", Rows(Read()["guidedmissions.rows"])[1][3] == "2/3")
inst:Fire("picksomething", { object = { prefab = "flower" } })
Check("picks done, sanity still short", Read()["guidedmissions.state"] == "active")
inst.components.sanity = { max = 200 }
-- 0.5 -> 0.575 of a 200-point bar is 15 points restored.
inst:Fire("sanitydelta", { oldpercent = 0.50, newpercent = 0.575 })
Complete("mission7")

-- 11b. Hitting Rock Bottom: a finished MINE swing on a boulder, plus gold.
state = Read()
Check("mission8 title", state["guidedmissions.title"] == "Hitting Rock Bottom")
Check("mine row icon is rocks", Rows(state["guidedmissions.rows"])[1][2] == "rocks")
inst:Fire("working", { target = Target({}, ACTIONS.MINE, 2) })
Check("partial mine swing does not count",
    Rows(Read()["guidedmissions.rows"])[1][3] == "0/3")
inst:Fire("working", { target = Target({}, ACTIONS.MINE, 0) })
inst:Fire("working", { target = Target({}, ACTIONS.CHOP, 0) })
Check("chopping is not mining", Rows(Read()["guidedmissions.rows"])[1][3] == "1/3")
inst:Fire("working", { target = Target({}, ACTIONS.MINE, 0) })
inst:Fire("working", { target = Target({}, ACTIONS.MINE, 0) })
Check("rocks done, gold still short", Read()["guidedmissions.state"] == "active")
Carry(inst, "goldnugget", 2)
Advance(1)
Complete("mission8")

-- 11c. Stience!: the Science Machine is a structure, so only `buildstructure`,
-- and the mission also asks for two newly learned recipes.
state = Read()
Check("mission9 title", state["guidedmissions.title"] == "Stience!")
Check("prototype row uses the blueprint icon",
    Rows(state["guidedmissions.rows"])[2][2] == "blueprint")
inst:Fire("builditem", Build("researchlab"))
Check("build ignores builditem", Read()["guidedmissions.state"] == "active")
inst:Fire("buildstructure", Build("researchlab"))
Check("build done, prototypes still short", Read()["guidedmissions.state"] == "active")
inst:Fire("unlockrecipe", { recipe = "boards" })
Check("one prototype counts",
    Rows(Read()["guidedmissions.rows"])[2][3] == "1/2")
inst:Fire("unlockrecipe", { recipe = "boards" })
Check("repeated unlock does not double count",
    Rows(Read()["guidedmissions.rows"])[2][3] == "1/2")
inst:Fire("unlockrecipe", { recipe = "spear" })
Complete("mission9")

-- 11d. A Little Protection: armor and weapons are inventory items.
state = Read()
Check("mission10 title", state["guidedmissions.title"] == "A Little Protection")
inst:Fire("builditem", Build("armorwood"))
Check("one recipe stays active", Read()["guidedmissions.state"] == "active")
inst:Fire("builditem", Build("spear"))
Complete("mission10")

-- 11e. Home Is Where the Fire Is: both are structures in the world.
state = Read()
Check("mission11 title", state["guidedmissions.title"] == "Home Is Where the Fire Is")
inst:Fire("buildstructure", Build("firepit"))
Check("one structure stays active", Read()["guidedmissions.state"] == "active")
inst:Fire("buildstructure", Build("treasurechest"))
Complete("mission11")

-- 11f. The Kitchen Experiment: two structures plus a Crock Pot meal.
state = Read()
Check("mission12 title", state["guidedmissions.title"] == "The Kitchen Experiment")
inst:Fire("buildstructure", Build("cookpot"))
inst:Fire("buildstructure", Build("meatrack"))
Check("structures done, meal still ahead", Read()["guidedmissions.state"] == "active")
inst:Fire("guidedmissions_stewedfood", { product = "meatballs" })
Complete("mission12")

-- 11g. Preparing for the Long Haul: peak holdings across three resources,
-- seeded by whatever the player already carries.
state = Read()
Check("mission13 title", state["guidedmissions.title"] == "Preparing for the Long Haul")
Check("logs start from the carried stock",
    Rows(state["guidedmissions.rows"])[1][3] == "10/20")
Check("twigs start from the carried stock",
    Rows(state["guidedmissions.rows"])[2][3] == "15/30")
Check("grass starts from the carried stock",
    Rows(state["guidedmissions.rows"])[3][3] == "10/30")
Carry(inst, "log", 10)
Carry(inst, "twigs", 15)
Advance(1)
Check("two of three resources still short", Read()["guidedmissions.state"] == "active")
Carry(inst, "cutgrass", 20)
Advance(1)
Complete("mission13")

-- The last mission ends in the terminal `done` payload.
state = Read()
Check("final state done", state["guidedmissions.state"] == "done")
Check("final title", state["guidedmissions.title"] == "All Missions Complete")
Check("final subtext", state["guidedmissions.subtext"] == "You survived. For now.")
Check("final rows empty", state["guidedmissions.rows"] == "")

-- 12. Save/load round trip keeps the finished chain finished.
manager:OnLoad(manager:OnSave())
Check("save/load keeps done", Read()["guidedmissions.state"] == "done")

-- 13. Removing the entity during a completion hold cancels every task it made.
local inst2 = NewInst(5678)
Netvars.Attach(inst2)
local manager2 = Manager(inst2)
Advance(1)
manager2.progress[1] = 3
manager2.progress[2] = 10
manager2.progress[3] = 10
manager2:CheckCompletion()
Check("hold pending after completion", manager2.hold_task ~= nil)
Check("hold payload won", Read(inst2)["guidedmissions.state"] == "won")
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

-- 14. Inventory reconciliation: a pickup that stacks into an existing stack
-- fires no `itemget` (and no other player event), so only the poll can see it.
local inst3 = NewInst(9012)
Netvars.Attach(inst3)
local manager3 = Manager(inst3)
Advance(1)
Check("reconcile starts at 0/10", Rows(Read(inst3)["guidedmissions.rows"])[2][3] == "0/10")

-- Ten twigs arrive in one inventory stack, with no event fired at all.
Carry(inst3, "twigs", 10)
Advance(1)
local rows3 = Rows(Read(inst3)["guidedmissions.rows"])
Check("reconcile counts stacked twigs", rows3[2][3] == "10/10")
Check("reconcile still active", Read(inst3)["guidedmissions.state"] == "active")

-- `itemget` must not grant progress. GiveActiveItem re-fires it every time an
-- item is clicked onto the cursor, which was the counter-inflation exploit.
inst3:Fire("itemget", Item("flint", 3))
inst3:Fire("itemget", Item("flint", 3))
rows3 = Rows(Read(inst3)["guidedmissions.rows"])
Check("itemget cannot inflate flint", rows3[1][3] == "0/3")
Check("itemget cannot complete mission", Read(inst3)["guidedmissions.state"] == "active")

Carry(inst3, "flint", 3)
Carry(inst3, "cutgrass", 10)
Advance(1)
Check("reconcile completes mission", Read(inst3)["guidedmissions.state"] == "won")

-- 15. Reset (the /resetmissions command) abandons the completion hold and
-- restarts at mission 1. With an empty inventory the counters are back to zero.
inst3.items = {}
manager3:Reset()
Check("reset title", Read(inst3)["guidedmissions.title"] == "Basic Supplies")
Check("reset state active", Read(inst3)["guidedmissions.state"] == "active")
Check("reset row1 counter", Rows(Read(inst3)["guidedmissions.rows"])[1][3] == "0/3")
Check("reset row2 counter", Rows(Read(inst3)["guidedmissions.rows"])[2][3] == "0/10")

-- 16. JumpTo (/setmission) goes straight to a mission, rejects out-of-range
-- indices, and can show the terminal completion state.
Check("jump to mission 5 accepted", manager3:JumpTo(5))
Check("jump title", Read(inst3)["guidedmissions.title"] == "Food for Thought")
Check("jump state active", Read(inst3)["guidedmissions.state"] == "active")
Check("jump to mission 5 counter", Rows(Read(inst3)["guidedmissions.rows"])[1][3] == "0/5")

Check("jump rejects 0", manager3:JumpTo(0) == false)
Check("jump rejects past the end", manager3:JumpTo(#Missions + 2) == false)
Check("jump rejects text", manager3:JumpTo("abc") == false)
Check("rejected jump changes nothing", Read(inst3)["guidedmissions.title"] == "Food for Thought")

Check("jump to completion accepted", manager3:JumpTo(#Missions + 1))
Check("jump completion state", Read(inst3)["guidedmissions.state"] == "done")

-- 17. Chop objectives count felled trees, not individual swings, stumps,
-- mined rocks, or the `working` event a wet tool pushes with no target.
-- (The Target helper lives with the walkthrough helpers above.)
local inst4 = NewInst(3456)
Netvars.Attach(inst4)
local manager4 = Manager(inst4)
Advance(1)
manager4.current_mission = {
    id = "test_chop",
    title = "Timber",
    subtext = "Trees.",
    objectives = {
        { type = "chop", count = 2, label = "Chop down trees" },
    },
}
manager4.progress = { 0 }
manager4.completed = false
manager4:Sync()
Check("chop starts at 0/2", Rows(Read(inst4)["guidedmissions.rows"])[1][3] == "0/2")
Check("chop row icon is log", Rows(Read(inst4)["guidedmissions.rows"])[1][2] == "log")

inst4:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 3) })
Check("partial chop does not count",
    Rows(Read(inst4)["guidedmissions.rows"])[1][3] == "0/2")

inst4:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
Check("felled tree counts", Rows(Read(inst4)["guidedmissions.rows"])[1][3] == "1/2")

inst4:Fire("working", { target = Target({ tree = true, stump = true }, ACTIONS.DIG, 0) })
Check("digging a stump does not count",
    Rows(Read(inst4)["guidedmissions.rows"])[1][3] == "1/2")

inst4:Fire("working", { target = Target({ tree = true }, ACTIONS.MINE, 0) })
Check("mining a marble tree does not count",
    Rows(Read(inst4)["guidedmissions.rows"])[1][3] == "1/2")

inst4:Fire("working", {})
Check("working with no target is ignored",
    Rows(Read(inst4)["guidedmissions.rows"])[1][3] == "1/2")

inst4:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
Check("second felled tree completes chop mission",
    Read(inst4)["guidedmissions.state"] == "won")

-- 18. Eat objectives fire on the eater's `oneat` event and match the food prefab.
local inst5 = NewInst(6789)
Netvars.Attach(inst5)
local manager5 = Manager(inst5)
Advance(1)
manager5.current_mission = {
    id = "test_eat",
    title = "Snack",
    subtext = "Anything is food if you believe.",
    objectives = {
        { type = "eat", prefab = "butterflywings", count = 1, label = "Eat butterfly wings" },
    },
}
manager5.progress = { 0 }
manager5.completed = false
manager5:Sync()

inst5:Fire("oneat", { food = { prefab = "carrot" } })
Check("eating other food does not count", Read(inst5)["guidedmissions.state"] == "active")

inst5:Fire("oneat", { food = { prefab = "butterflywings" } })
Check("eating the target food completes eat mission",
    Read(inst5)["guidedmissions.state"] == "won")

-- 19. Heal objectives credit the requested heal amount, not the points that
-- fit on the bar: a +10 eaten at 98/100 credits 10, and a heal at full health
-- credits its whole amount as overheal. Damage and no-op deltas count nothing.
local inst6 = NewInst(2468)
inst6.components.health = { maxhealth = 100 }
Netvars.Attach(inst6)
local manager6 = Manager(inst6)
Advance(1)
manager6.current_mission = {
    id = "test_heal",
    title = "Patch Up",
    subtext = "Ouch.",
    objectives = {
        { type = "heal", count = 20, label = "Restore health" },
    },
}
manager6.progress = { 0 }
manager6.completed = false
manager6:Sync()
Check("heal row icon is healingsalve",
    Rows(Read(inst6)["guidedmissions.rows"])[1][2] == "healingsalve")

inst6:Fire("healthdelta", { oldpercent = 0.50, newpercent = 0.56, amount = 6 })
Check("heal counts the requested amount",
    Rows(Read(inst6)["guidedmissions.rows"])[1][3] == "6/20")

inst6:Fire("healthdelta", { oldpercent = 0.56, newpercent = 0.50, amount = -6 })
Check("damage does not count",
    Rows(Read(inst6)["guidedmissions.rows"])[1][3] == "6/20")

inst6:Fire("healthdelta", { oldpercent = 0.98, newpercent = 1.00, amount = 10 })
Check("clamped heal counts its full requested amount",
    Rows(Read(inst6)["guidedmissions.rows"])[1][3] == "16/20")

inst6:Fire("healthdelta", { oldpercent = 1.00, newpercent = 1.00, amount = 0 })
Check("no-op delta does not count",
    Rows(Read(inst6)["guidedmissions.rows"])[1][3] == "16/20")

inst6:Fire("healthdelta", { oldpercent = 1.00, newpercent = 1.00, amount = 4 })
Check("heal mission completes from overheal at full health",
    Read(inst6)["guidedmissions.state"] == "won")

-- 19b. Sanity objectives likewise credit the requested delta recorded on the
-- component (sanitydelta itself carries no amount), including overflow at full
-- sanity; the percent difference remains as a fallback.
local inst6b = NewInst(2469)
inst6b.components.sanity = { max = 100 }
Netvars.Attach(inst6b)
local manager6b = Manager(inst6b)
Advance(1)
manager6b.current_mission = {
    id = "test_sanity",
    title = "Settle Down",
    subtext = "Breathe.",
    objectives = {
        { type = "sanity", count = 20, label = "Restore sanity" },
    },
}
manager6b.progress = { 0 }
manager6b.completed = false
manager6b:Sync()

inst6b:Fire("sanitydelta", { oldpercent = 0.50, newpercent = 0.56 })
Check("sanity falls back to the percent difference",
    Rows(Read(inst6b)["guidedmissions.rows"])[1][3] == "6/20")

inst6b.components.sanity._guidedmissions_last_delta = 10
inst6b:Fire("sanitydelta", { oldpercent = 0.98, newpercent = 1.00 })
Check("sanity counts the recorded requested delta",
    Rows(Read(inst6b)["guidedmissions.rows"])[1][3] == "16/20")

inst6b.components.sanity._guidedmissions_last_delta = -10
inst6b:Fire("sanitydelta", { oldpercent = 1.00, newpercent = 1.00 })
Check("sanity loss does not count",
    Rows(Read(inst6b)["guidedmissions.rows"])[1][3] == "16/20")

inst6b.components.sanity._guidedmissions_last_delta = 4
inst6b:Fire("sanitydelta", { oldpercent = 1.00, newpercent = 1.00 })
Check("sanity mission completes from overflow at full sanity",
    Read(inst6b)["guidedmissions.state"] == "won")

-- 20. Mine objectives count finished MINE work (boulders, rocks) and ignore
-- partial swings, other work actions, and targetless working events.
local inst7 = NewInst(1357)
Netvars.Attach(inst7)
local manager7 = Manager(inst7)
Advance(1)
manager7.current_mission = {
    id = "test_mine",
    title = "Rock Bottom",
    subtext = "Swing.",
    objectives = {
        { type = "mine", count = 2, label = "Mine boulders" },
    },
}
manager7.progress = { 0 }
manager7.completed = false
manager7:Sync()
Check("mine row icon is rocks",
    Rows(Read(inst7)["guidedmissions.rows"])[1][2] == "rocks")

inst7:Fire("working", { target = Target({}, ACTIONS.MINE, 2) })
Check("partial mine does not count",
    Rows(Read(inst7)["guidedmissions.rows"])[1][3] == "0/2")

inst7:Fire("working", { target = Target({ tree = true }, ACTIONS.CHOP, 0) })
Check("chopping does not count as mining",
    Rows(Read(inst7)["guidedmissions.rows"])[1][3] == "0/2")

inst7:Fire("working", { target = Target({}, ACTIONS.DIG, 0) })
Check("digging does not count as mining",
    Rows(Read(inst7)["guidedmissions.rows"])[1][3] == "0/2")

inst7:Fire("working", {})
Check("mine ignores targetless working",
    Rows(Read(inst7)["guidedmissions.rows"])[1][3] == "0/2")

inst7:Fire("working", { target = Target({}, ACTIONS.MINE, 0) })
Check("mined node counts", Rows(Read(inst7)["guidedmissions.rows"])[1][3] == "1/2")

inst7:Fire("working", { target = Target({}, ACTIONS.MINE, 0) })
Check("mining mission completes", Read(inst7)["guidedmissions.state"] == "won")

-- 21. Pick objectives count plants picked (flower picking is what restores
-- sanity; petals themselves give no sanity).
local inst8 = NewInst(8642)
Netvars.Attach(inst8)
local manager8 = Manager(inst8)
Advance(1)
manager8.current_mission = {
    id = "test_pick",
    title = "Flower Power",
    subtext = "Petals.",
    objectives = {
        { type = "pick", prefab = "flower", count = 2, label = "Pick flowers", icon = "petals" },
    },
}
manager8.progress = { 0 }
manager8.completed = false
manager8:Sync()
Check("pick row icon override",
    Rows(Read(inst8)["guidedmissions.rows"])[1][2] == "petals")

inst8:Fire("picksomething", { object = { prefab = "flower_evil" } })
Check("evil flower does not count",
    Rows(Read(inst8)["guidedmissions.rows"])[1][3] == "0/2")

inst8:Fire("picksomething", { object = { prefab = "flower" } })
Check("picked flower counts", Rows(Read(inst8)["guidedmissions.rows"])[1][3] == "1/2")

inst8:Fire("picksomething", { object = { prefab = "flower" } })
Check("pick mission completes", Read(inst8)["guidedmissions.state"] == "won")

-- 22. Sanity objectives credit actual sanity restored from sanitydelta and
-- ignore sanity drain. The event has no amount, so max sanity is the scale.
local inst9 = NewInst(9753)
inst9.components.sanity = { max = 200 }
Netvars.Attach(inst9)
local manager9 = Manager(inst9)
Advance(1)
manager9.current_mission = {
    id = "test_sanity",
    title = "Clear Mind",
    subtext = "Think happy thoughts.",
    objectives = {
        { type = "sanity", count = 10, label = "Restore sanity" },
    },
}
manager9.progress = { 0 }
manager9.completed = false
manager9:Sync()
Check("sanity row is text-only",
    Rows(Read(inst9)["guidedmissions.rows"])[1][2] == "")

inst9:Fire("sanitydelta", { oldpercent = 0.50, newpercent = 0.53 })
Check("sanity counts restored points",
    Rows(Read(inst9)["guidedmissions.rows"])[1][3] == "6/10")

inst9:Fire("sanitydelta", { oldpercent = 0.53, newpercent = 0.50 })
Check("sanity drain does not count",
    Rows(Read(inst9)["guidedmissions.rows"])[1][3] == "6/10")

inst9:Fire("sanitydelta", { oldpercent = 0.50, newpercent = 0.52 })
Check("sanity mission completes", Read(inst9)["guidedmissions.state"] == "won")

-- 23. collect_food objectives count carried edible items (peak holdings, like collect).
local inst10 = NewInst(1122)
Netvars.Attach(inst10)
local manager10 = Manager(inst10)
Advance(1)
manager10.current_mission = {
    id = "test_food",
    title = "Food for Thought",
    subtext = "Something edible.",
    objectives = {
        { type = "collect_food", count = 3, label = "Collect food" },
    },
}
manager10.progress = { 0 }
manager10.completed = false
manager10:Sync()
Check("food row is text-only", Rows(Read(inst10)["guidedmissions.rows"])[1][2] == "")

Carry(inst10, "flint", 5)
Advance(1)
Check("non-food does not count",
    Rows(Read(inst10)["guidedmissions.rows"])[1][3] == "0/3")

CarryFood(inst10, "berries", 2, "VEGGIE", "BERRY")
Advance(1)
Check("food counts stack size",
    Rows(Read(inst10)["guidedmissions.rows"])[1][3] == "2/3")

CarryFood(inst10, "carrot", 1, "VEGGIE", nil)
Advance(1)
Check("food mission completes", Read(inst10)["guidedmissions.state"] == "won")

-- 23b. secondaryfoodtype filter: BERRY matches both berries and juicy berries.
local inst11 = NewInst(2233)
Netvars.Attach(inst11)
local manager11 = Manager(inst11)
Advance(1)
manager11.current_mission = {
    id = "test_berries",
    title = "Berry Picking",
    subtext = "Red and round.",
    objectives = {
        { type = "collect_food", count = 2, secondaryfoodtype = "BERRY", label = "Collect berries" },
    },
}
manager11.progress = { 0 }
manager11.completed = false
manager11:Sync()

CarryFood(inst11, "carrot", 2, "VEGGIE", nil)
Advance(1)
Check("non-berry food is filtered out",
    Rows(Read(inst11)["guidedmissions.rows"])[1][3] == "0/2")

CarryFood(inst11, "berries", 1, "VEGGIE", "BERRY")
Advance(1)
Check("berries count", Rows(Read(inst11)["guidedmissions.rows"])[1][3] == "1/2")

CarryFood(inst11, "berries_juicy", 1, "VEGGIE", "BERRY")
Advance(1)
Check("juicy berries count", Read(inst11)["guidedmissions.state"] == "won")

-- 24. Cook objectives fire on the `guidedmissions_cookedfood` event modmain pushes for fire
-- cooking (any edible product). The row uses "Cook food" when no prefab is set.
local inst12 = NewInst(3344)
Netvars.Attach(inst12)
local manager12 = Manager(inst12)
Advance(1)
manager12.current_mission = {
    id = "test_cook",
    title = "Warm Meal",
    subtext = "Fire makes it better.",
    objectives = {
        { type = "cook", count = 2 },
    },
}
manager12.progress = { 0 }
manager12.completed = false
manager12:Sync()
Check("cook row label is Cook food",
    Rows(Read(inst12)["guidedmissions.rows"])[1][1] == "Cook food")

inst12:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedmeat" } })
Check("cooked food counts",
    Rows(Read(inst12)["guidedmissions.rows"])[1][3] == "1/2")

inst12:Fire("guidedmissions_cookedfood", { product = { prefab = "cookedcarrot" } })
Check("cook mission completes", Read(inst12)["guidedmissions.state"] == "won")

-- 25. Prototype objectives count each newly learned recipe once. Recipes in
-- the builder's learned list are seeded as already known, and repeated unlock
-- events (vanilla re-pushes for structure placement) do not double count.
local inst13 = NewInst(4455)
inst13.components.builder = { recipes = { "goldenaxe" } }
Netvars.Attach(inst13)
local manager13 = Manager(inst13)
Advance(1)
manager13.current_mission = {
    id = "test_prototype",
    title = "Eureka",
    subtext = "Knowledge.",
    objectives = {
        { type = "prototype", count = 2 },
    },
}
manager13.progress = { 0 }
manager13.completed = false
manager13:Sync()
Check("prototype row label is Prototype new recipes",
    Rows(Read(inst13)["guidedmissions.rows"])[1][1] == "Prototype new recipes")
Check("prototype row uses the blueprint icon by default",
    Rows(Read(inst13)["guidedmissions.rows"])[1][2] == "blueprint")

inst13:Fire("unlockrecipe")
Check("data-less unlockrecipe is ignored",
    Rows(Read(inst13)["guidedmissions.rows"])[1][3] == "0/2")

inst13:Fire("unlockrecipe", { recipe = "goldenaxe" })
Check("already-known recipe is ignored",
    Rows(Read(inst13)["guidedmissions.rows"])[1][3] == "0/2")

inst13:Fire("unlockrecipe", { recipe = "spear" })
Check("new recipe counts", Rows(Read(inst13)["guidedmissions.rows"])[1][3] == "1/2")

inst13:Fire("unlockrecipe", { recipe = "spear" })
Check("repeated unlock does not double count",
    Rows(Read(inst13)["guidedmissions.rows"])[1][3] == "1/2")

inst13:Fire("unlockrecipe", { recipe = "backpack" })
Check("prototype mission completes", Read(inst13)["guidedmissions.state"] == "won")

-- 25b. Optional `recipe` narrows the objective to one recipe.
local inst14 = NewInst(5566)
inst14.components.builder = { recipes = {} }
Netvars.Attach(inst14)
local manager14 = Manager(inst14)
Advance(1)
manager14.current_mission = {
    id = "test_prototype_goldenaxe",
    title = "Golden Idea",
    subtext = "Shiny.",
    objectives = {
        { type = "prototype", recipe = "goldenaxe", count = 1, label = "Prototype a golden axe" },
    },
}
manager14.progress = { 0 }
manager14.completed = false
manager14:Sync()
Check("targeted prototype row icon is the recipe id",
    Rows(Read(inst14)["guidedmissions.rows"])[1][2] == "goldenaxe")

inst14:Fire("unlockrecipe", { recipe = "spear" })
Check("other recipes are filtered out",
    Rows(Read(inst14)["guidedmissions.rows"])[1][3] == "0/1")

inst14:Fire("unlockrecipe", { recipe = "goldenaxe" })
Check("targeted prototype mission completes",
    Read(inst14)["guidedmissions.state"] == "won")

-- 26. Crockpot objectives fire on the `guidedmissions_stewedfood` event
-- modmain pushes when a pot starts cooking.
local inst15 = NewInst(6677)
Netvars.Attach(inst15)
local manager15 = Manager(inst15)
Advance(1)
manager15.current_mission = {
    id = "test_cookpot",
    title = "Pot Luck",
    subtext = "Stir.",
    objectives = {
        { type = "cookpot", count = 2 },
    },
}
manager15.progress = { 0 }
manager15.completed = false
manager15:Sync()
Check("cookpot row label is Cook in a Crock Pot",
    Rows(Read(inst15)["guidedmissions.rows"])[1][1] == "Cook in a Crock Pot")
Check("cookpot row is text-only",
    Rows(Read(inst15)["guidedmissions.rows"])[1][2] == "")

inst15:Fire("guidedmissions_stewedfood", { product = "meatballs" })
Check("crockpot dish counts",
    Rows(Read(inst15)["guidedmissions.rows"])[1][3] == "1/2")

inst15:Fire("guidedmissions_stewedfood", { product = "wetgoop" })
Check("cookpot mission completes", Read(inst15)["guidedmissions.state"] == "won")

-- 26b. Optional `prefab` filters to one dish and does not react to fire cooking.
local inst16 = NewInst(7788)
Netvars.Attach(inst16)
local manager16 = Manager(inst16)
Advance(1)
manager16.current_mission = {
    id = "test_cookpot_meatballs",
    title = "Meatballs",
    subtext = "Round.",
    objectives = {
        { type = "cookpot", prefab = "meatballs", count = 1, label = "Cook meatballs" },
    },
}
manager16.progress = { 0 }
manager16.completed = false
manager16:Sync()
Check("cookpot row icon is the dish prefab",
    Rows(Read(inst16)["guidedmissions.rows"])[1][2] == "meatballs")

inst16:Fire("guidedmissions_cookedfood", { product = { prefab = "meatballs" } })
Check("fire cooking does not satisfy a cookpot objective",
    Rows(Read(inst16)["guidedmissions.rows"])[1][3] == "0/1")

inst16:Fire("guidedmissions_stewedfood", { product = "wetgoop" })
Check("other dishes are filtered out",
    Rows(Read(inst16)["guidedmissions.rows"])[1][3] == "0/1")

inst16:Fire("guidedmissions_stewedfood", { product = "meatballs" })
Check("targeted cookpot mission completes",
    Read(inst16)["guidedmissions.state"] == "won")

print(failures == 0 and "ALL PASS" or ("FAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
