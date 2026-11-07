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

-- 1. startup: the first mission is active with both rows and zero counters.
Advance(1)
local state = Read()
Check("startup state active", state["guidedmissions.state"] == "active")
Check("startup title", state["guidedmissions.title"] == "Basic Supplies")
Check("startup subtext", state["guidedmissions.subtext"] == "Rock. Stick. Civilisation, basically.")
Check("startup rows count 2", #Rows(state["guidedmissions.rows"]) == 2)
Check("startup row1 label", Rows(state["guidedmissions.rows"])[1][1] == "Collect flint")
Check("startup row1 prefab", Rows(state["guidedmissions.rows"])[1][2] == "flint")
Check("startup row1 counter", Rows(state["guidedmissions.rows"])[1][3] == "0/3")
Check("startup row2 counter", Rows(state["guidedmissions.rows"])[2][3] == "0/2")
Check("mission start not announced in chat", #announcements == 0)

-- 2. Partial progress ticks without completing. Collect progress is read from
-- the inventory on the poll; events never add to it.
Carry(inst, "flint", 2)
Advance(1)
state = Read()
Check("partial counter 2/3", Rows(state["guidedmissions.rows"])[1][3] == "2/3")
Check("still active", state["guidedmissions.state"] == "active")

-- 3. Completion writes the `won` payload with every row forced done.
Carry(inst, "flint", 1)
Carry(inst, "twigs", 2)
Advance(1)
state = Read()
Check("mission1 won", state["guidedmissions.state"] == "won")
Check("won row1 done", Rows(state["guidedmissions.rows"])[1][4] == "1")
Check("won row2 done", Rows(state["guidedmissions.rows"])[2][4] == "1")
Check("won row1 counter full", Rows(state["guidedmissions.rows"])[1][3] == "3/3")
Check("completion announced in chat",
    announcements[#announcements] == "Wilson completed: Basic Supplies")

-- Progress during the hold is ignored: there is no current mission, so even
-- the inventory poll has nothing to update.
Carry(inst, "twigs", 5)
Advance(1)
Check("hold still won", Read()["guidedmissions.state"] == "won")

-- 4. After the hold the next mission starts, quietly.
local announce_count = #announcements
Advance(3)
state = Read()
Check("mission2 active", state["guidedmissions.state"] == "active")
Check("mission2 title", state["guidedmissions.title"] == "A Wooden Start")
Check("mission2 rows count 1", #Rows(state["guidedmissions.rows"]) == 1)
Check("mission start not announced in chat", #announcements == announce_count)

local function Complete(label)
    Check(label .. " won", Read()["guidedmissions.state"] == "won")
    Advance(3)
end

-- 5. A Wooden Start
Carry(inst, "log", 10)
Advance(1)
Complete("mission2")
state = Read()
Check("mission3 title", state["guidedmissions.title"] == "Light the Night")

-- 6. Light the Night: a torch is an inventory item, so only `builditem` counts.
inst:Fire("buildstructure", Build("torch"))
Check("craft ignores buildstructure", Read()["guidedmissions.state"] == "active")
inst:Fire("builditem", Build("torch"))
Complete("mission3")
state = Read()
Check("mission4 title", state["guidedmissions.title"] == "See the Dawn")
Check("mission4 counter", Rows(state["guidedmissions.rows"])[1][3] == "Day 1/3")
Check("mission4 icon empty", Rows(state["guidedmissions.rows"])[1][2] == "")

-- 7. See the Dawn: the poll sees cycles = 2 as day 3.
TheWorld.state.cycles = 2
Advance(1)
state = Read()
Check("mission4 counter day 3", Rows(state["guidedmissions.rows"])[1][3] == "Day 3/3")
Complete("mission4")
state = Read()
Check("mission5 title", state["guidedmissions.title"] == "A Proper Camp")

-- 8. A Proper Camp. A firepit is a structure, not an inventory item, so the
-- engine fires `buildstructure` (builder.lua), never `builditem`; the craft
-- event must not satisfy a build objective.
inst:Fire("builditem", Build("firepit"))
Check("build ignores builditem", Read()["guidedmissions.state"] == "active")
inst:Fire("buildstructure", Build("firepit"))
Complete("mission5")

-- 9. Clear the Nest
inst:Fire("killed", { victim = { prefab = "spider" } })
inst:Fire("killed", { victim = { prefab = "spider" } })
inst:Fire("killed", { victim = { prefab = "spider" } })
Complete("mission6")
state = Read()
Check("mission7 title", state["guidedmissions.title"] == "Prospector")

-- 10. Prospector
Carry(inst, "goldnugget", 3)
Advance(1)
Complete("mission7")
state = Read()
Check("mission8 title", state["guidedmissions.title"] == "Science!")

-- 11. Science!: the last mission ends in the terminal `done` payload. The
-- Science Machine is also a structure (`buildstructure`).
inst:Fire("builditem", Build("researchlab"))
Check("build ignores builditem (researchlab)", Read()["guidedmissions.state"] == "active")
inst:Fire("buildstructure", Build("researchlab"))
Complete("mission8")
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
manager2.progress[2] = 2
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
Check("reconcile starts at 0/2", Rows(Read(inst3)["guidedmissions.rows"])[2][3] == "0/2")

-- Two twigs arrive in one inventory stack, with no event fired at all.
Carry(inst3, "twigs", 2)
Advance(1)
local rows3 = Rows(Read(inst3)["guidedmissions.rows"])
Check("reconcile counts stacked twigs", rows3[2][3] == "2/2")
Check("reconcile still active", Read(inst3)["guidedmissions.state"] == "active")

-- `itemget` must not grant progress. GiveActiveItem re-fires it every time an
-- item is clicked onto the cursor, which was the counter-inflation exploit.
inst3:Fire("itemget", Item("flint", 3))
inst3:Fire("itemget", Item("flint", 3))
rows3 = Rows(Read(inst3)["guidedmissions.rows"])
Check("itemget cannot inflate flint", rows3[1][3] == "0/3")
Check("itemget cannot complete mission", Read(inst3)["guidedmissions.state"] == "active")

Carry(inst3, "flint", 3)
Advance(1)
Check("reconcile completes mission", Read(inst3)["guidedmissions.state"] == "won")

-- 15. Reset (the /resetmissions command) abandons the completion hold and
-- restarts at mission 1. With an empty inventory the counters are back to zero.
inst3.items = {}
manager3:Reset()
Check("reset title", Read(inst3)["guidedmissions.title"] == "Basic Supplies")
Check("reset state active", Read(inst3)["guidedmissions.state"] == "active")
Check("reset row1 counter", Rows(Read(inst3)["guidedmissions.rows"])[1][3] == "0/3")
Check("reset row2 counter", Rows(Read(inst3)["guidedmissions.rows"])[2][3] == "0/2")

-- 16. JumpTo (/setmission) goes straight to a mission, rejects out-of-range
-- indices, and can show the terminal completion state.
Check("jump to mission 5 accepted", manager3:JumpTo(5))
Check("jump title", Read(inst3)["guidedmissions.title"] == "A Proper Camp")
Check("jump state active", Read(inst3)["guidedmissions.state"] == "active")
Check("jump to mission 5 counter", Rows(Read(inst3)["guidedmissions.rows"])[1][3] == "0/1")

Check("jump rejects 0", manager3:JumpTo(0) == false)
Check("jump rejects past the end", manager3:JumpTo(#Missions + 2) == false)
Check("jump rejects text", manager3:JumpTo("abc") == false)
Check("rejected jump changes nothing", Read(inst3)["guidedmissions.title"] == "A Proper Camp")

Check("jump to completion accepted", manager3:JumpTo(#Missions + 1))
Check("jump completion state", Read(inst3)["guidedmissions.state"] == "done")

print(failures == 0 and "ALL PASS" or ("FAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
