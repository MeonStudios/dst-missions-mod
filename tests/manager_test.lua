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
-- `meta.session_identifier` is the shard's persistent world-session id; the
-- manager stamps saves with it to tell a live shard transfer from a stale
-- migration record in a save file. `TheShard:GetShardId()` is this shard.
TheWorld = { state = { cycles = 0 }, meta = { session_identifier = "HARNESS_WORLD_SESSION" } }
TheShard = { GetShardId = function() return "HARNESS_SHARD" end }
-- Connected players, used by the `ghost_nearby` condition's cheap
-- "is anyone else even here" check. `Spawn` appends every fixture player.
AllPlayers = {}
-- Nearby world entities for `shared` build rows. The stub filters by tag and
-- radius the way the engine does, so the `structure` tag filter and the radius
-- are exercised rather than mocked away. Entries:
-- `{ prefab = "firepit", x = 0, z = 0, tags = { structure = true } }`.
TheSim = {
    entities = {},
    FindEntities = function(_, x, y, z, radius, musttags)
        local found = {}
        for _, entity in ipairs(TheSim.entities) do
            local tagged = true
            for _, tag in ipairs(musttags or {}) do
                if not (entity.tags or {})[tag] then
                    tagged = false
                end
            end
            local dx = (entity.x or 0) - x
            local dz = (entity.z or 0) - z
            if tagged and dx * dx + dz * dz <= radius * radius then
                found[#found + 1] = entity
            end
        end
        return found
    end,
}
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

-- `WatchWorldState` callbacks, per world-state variable. The real worldstate
-- component calls each watcher after storing the new value (`SetVariable` in
-- scripts/components/worldstate.lua); `SetDay` below reproduces that order.
local worldstate_watchers = {}

local function NewInst(guid)
    local inst = {
        GUID = guid,
        -- Character prefab id. Fixtures override this to exercise character
        -- overrides; the real manager reads `player.prefab` the same way.
        prefab = "wilson",
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
        -- Currently equipped items, keyed by EQUIPSLOTS ("hands", "head",
        -- "body", "beard"). `equip` objectives read this live, exactly as
        -- `Inventory.equipslots` holds them in the game.
        equipslots = {},
    }
    function inst:ListenForEvent(event, fn)
        self._listeners[event] = self._listeners[event] or {}
        table.insert(self._listeners[event], fn)
    end
    -- The manager watches `cycles` for day-based emergency triggers. Record the
    -- callback here; SetDay updates TheWorld.state first and then fires it, in
    -- the same order the engine's worldstate component does.
    function inst:WatchWorldState(var, fn)
        worldstate_watchers[var] = worldstate_watchers[var] or {}
        table.insert(worldstate_watchers[var], { inst = self, fn = fn })
    end
    function inst:DoPeriodicTask(period, fn)
        return NewTask(clock + period, fn, period, self)
    end
    function inst:DoTaskInTime(delay, fn)
        return NewTask(clock + delay, fn, nil, self)
    end
    -- World position for proximity reads (shared build rows). A fixture may
    -- set `inst.x` / `inst.z` before activation to stand elsewhere.
    inst.Transform = {
        GetWorldPosition = function()
            return inst.x or 0, 0, inst.z or 0
        end,
    }
    -- Player tags. The manager reads `playerghost` for the death card, and the
    -- fixture can add/remove it to simulate dying and reviving.
    inst.tags = {}
    function inst:HasTag(tag) return self.tags[tag] == true end
    function inst:AddTag(tag) self.tags[tag] = true end
    function inst:RemoveTag(tag) self.tags[tag] = nil end
    function inst:GetDisplayName() return "Wilson" end
    function inst:IsValid() return true end
    function inst:Fire(event, data)
        for _, fn in ipairs(self._listeners[event] or {}) do
            fn(self, data)
        end
    end
    return inst
end

-- Start a new world day the way the engine does: update
-- `TheWorld.state.cycles` (1-based day minus one) and only then invoke the
-- watchers. `target` limits the callback to one player's manager, so a fixture
-- day cannot pop cards on every earlier fixture.
local function SetDay(target, day)
    TheWorld.state.cycles = day - 1
    for _, watcher in ipairs(worldstate_watchers.cycles or {}) do
        if target == nil or watcher.inst == target then
            watcher.fn(watcher.inst, day - 1)
        end
    end
end

-- The walkthrough player; assigned once the manager module is loaded below.
local inst

local function Read(target)
    return netvars_by_inst[(target or inst).GUID] or {}
end

-- ---- harness -------------------------------------------------------------

local Netvars = require("guidedmissions/netvars")
local Objectives = require("guidedmissions/objectives")
local Conditions = require("guidedmissions/conditions")
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

-- Every stubbed item carries `HasTag` because the objective matcher reads tags
-- through it (`exclude_tags`) and a real inventory item always answers it.
local function StubItem(prefab, components, tags)
    local item = { prefab = prefab, components = components or {} }
    function item:HasTag(tag)
        return tags ~= nil and tags[tag] == true
    end
    return item
end

local function Item(prefab, stack_size)
    local components = {}
    if stack_size ~= nil then
        components.stackable = { StackSize = function() return stack_size end }
    end
    return { item = StubItem(prefab, components) }
end

local function Build(prefab)
    return { recipe = { name = prefab }, item = StubItem(prefab) }
end

-- Add a stack of `prefab` to the player's inventory. Collect objectives reread
-- this after an inventory event (the event payload carries no count).
local function Carry(target, prefab, count)
    target.items[#target.items + 1] = StubItem(prefab, {
        stackable = { StackSize = function() return count end },
    })
end

-- Add an edible item stack. `secondaryfoodtype` is how berries and
-- berries_juicy share the BERRY tag despite being main-type VEGGIE. `tags` is
-- the entity tag set the objective's `exclude_tags` filter reads (a Crock Pot
-- dish carries `preparedfood`).
local function CarryFood(target, prefab, count, foodtype, secondaryfoodtype, tags)
    target.items[#target.items + 1] = StubItem(prefab, {
        stackable = { StackSize = function() return count end },
        edible = { foodtype = foodtype, secondaryfoodtype = secondaryfoodtype },
    }, tags)
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
    sleep = true, fertilize = true, equip = true, deploy = true,
    -- `haunt` names either `prefab` or `tag`; the pair rule lives below.
    haunt = true,
}

-- Shared by chain and emergency validation. Returns `optional == true` so the
-- mission loop can count rows that gate completion.
local function ValidateObjectiveFields(where, objective, index)
    local row = string.format("%s objective %d (%s)", where, index, tostring(objective.type))
    Check(row .. " uses a known type", Objectives.VALID_TYPES[objective.type] == true)
    Check(row .. " optional flag is a boolean",
        objective.optional == nil or type(objective.optional) == "boolean")
    -- Only `build` reads `shared`; setting it elsewhere is silently inert and
    -- almost always a mistake (the row would never auto-complete).
    Check(row .. " shared flag is a boolean",
        objective.shared == nil or type(objective.shared) == "boolean")
    Check(row .. " shared is only set on build rows",
        objective.shared ~= true or objective.type == "build")
    -- `self` marks a `fertilize` row for fertilizing the player (Wormwood). It
    -- takes no plant filter: `prefab` on a self row would be read as the plant
    -- and could never match the player.
    Check(row .. " self flag is a boolean",
        objective.self == nil or type(objective.self) == "boolean")
    Check(row .. " self is only set on fertilize rows",
        objective.self ~= true or objective.type == "fertilize")
    Check(row .. " self rows do not filter a plant",
        objective.self ~= true or objective.prefab == nil)

    -- `tag` is the multi-entity form of a `haunt` filter (the Florid Postern
    -- and its Celestial Portal upgrade share `multiplayer_portal`).
    if objective.tag ~= nil then
        Check(row .. " tag is only set on haunt rows", objective.type == "haunt")
        Check(row .. " tag is a tag id", IsPrefabId(objective.tag))
    end

    -- `when` gates a row on a world setting. Only optional rows: a hidden
    -- required row would remove a mission's gate without the player seeing it.
    if objective.when ~= nil then
        Check(row .. " when is a table", type(objective.when) == "table")
        if type(objective.when) == "table" then
            Check(row .. " when names a known world setting",
                Conditions.VALID_WORLD_SETTINGS[objective.when.setting] == true)
        end
        Check(row .. " when is only on optional rows",
            Objectives.IsOptional(objective))
    end

    if needs_prefab[objective.type] then
        Check(row .. " names a prefab id", IsPrefabId(objective.prefab))
    elseif not optional_prefab[objective.type] and objective.type ~= "survive" then
        -- A prefab field on a type that ignores it is almost always a
        -- `collect`/`collect_food` mix-up; the two read different events.
        Check(row .. " does not set a prefab", objective.prefab == nil)
    elseif objective.prefab ~= nil then
        Check(row .. " prefab filter is a prefab id", IsPrefabId(objective.prefab))
    end

    -- `prefabs` is the multi-id form of a filter; `plant` and `collect_food`
    -- read it (an allow-list), so a list on any other type would silently
    -- match nothing.
    if objective.prefabs ~= nil then
        Check(row .. " prefabs is only set on plant or collect_food rows",
            objective.type == "plant" or objective.type == "collect_food")
        Check(row .. " does not set both prefab and prefabs", objective.prefab == nil)
        Check(row .. " prefabs is a non-empty table", type(objective.prefabs) == "table"
            and #objective.prefabs > 0)
        if type(objective.prefabs) == "table" then
            for i = 1, #objective.prefabs do
                Check(string.format("%s prefabs[%d] is a prefab id", row, i),
                    IsPrefabId(objective.prefabs[i]))
            end
        end
    end

    -- `exclude` / `exclude_tags` are the negative filters `collect_food` reads
    -- to drop VEGGIE-class items that are not vegetables (butterfly wings,
    -- Crock Pot dishes). Another type would silently ignore them.
    if objective.exclude ~= nil then
        Check(row .. " exclude is only set on collect_food rows",
            objective.type == "collect_food")
        Check(row .. " exclude is a non-empty table",
            type(objective.exclude) == "table" and #objective.exclude > 0)
        if type(objective.exclude) == "table" then
            for i = 1, #objective.exclude do
                Check(string.format("%s exclude[%d] is a prefab id", row, i),
                    IsPrefabId(objective.exclude[i]))
            end
        end
    end
    if objective.exclude_tags ~= nil then
        Check(row .. " exclude_tags is only set on collect_food rows",
            objective.type == "collect_food")
        Check(row .. " exclude_tags is a non-empty table",
            type(objective.exclude_tags) == "table" and #objective.exclude_tags > 0)
        if type(objective.exclude_tags) == "table" then
            for i = 1, #objective.exclude_tags do
                Check(string.format("%s exclude_tags[%d] is a tag id", row, i),
                    IsPrefabId(objective.exclude_tags[i]))
            end
        end
    end

    Check(row .. " has a label",
        type(objective.label) == "string" and #objective.label > 0)
    if objective.icon ~= nil then
        Check(row .. " icon is a prefab id", IsPrefabId(objective.icon))
    end

    if objective.type == "tip" then
        -- A tip is an informational row: no target, no progress, and always
        -- optional. Authoring `optional = false` does nothing at runtime, so
        -- reject the misleading flag.
        Check(row .. " does not set a count", objective.count == nil)
        Check(row .. " does not set optional = false", objective.optional ~= false)
    elseif objective.type == "survive" then
        Check(row .. " has a day", tonumber(objective.day) ~= nil)
    elseif objective.type == "reach_stat" then
        -- A live stat row has no count: it tracks a percentage against a
        -- threshold string on the same 0-100 scale as emergency conditions.
        Check(row .. " names a known stat",
            RealEmergencies.VALID_STATS[objective.stat] == true)
        local operator = RealEmergencies.ParseStatThreshold(
            objective.stat, objective.threshold)
        Check(row .. " threshold parses", operator ~= nil)
    elseif objective.type == "equip" then
        -- A live equipment row has no count: it is 0/1 for "currently
        -- equipped". Filters are optional and combine with AND.
        Check(row .. " does not set a count", objective.count == nil)
        Check(row .. " category is known",
            objective.category == nil
                or Objectives.EQUIP_CATEGORIES[objective.category] == true)
        Check(row .. " slot is known",
            objective.slot == nil
                or Objectives.EQUIP_SLOTS[objective.slot] == true)
    elseif objective.type == "haunt" then
        -- Exactly one filter: a prefab id or a tag. A tag row has no prefab to
        -- draw, so it must name its icon.
        Check(row .. " names exactly one of prefab or tag",
            (objective.prefab ~= nil) ~= (objective.tag ~= nil))
        Check(row .. " tag rows name an icon",
            objective.tag == nil or objective.icon ~= nil)
        Check(row .. " count is a positive whole number when set",
            objective.count == nil
                or (tonumber(objective.count) ~= nil
                    and tonumber(objective.count) >= 1))
    else
        Check(row .. " has a count", tonumber(objective.count) ~= nil)
    end

    -- Character overrides: `overrides` maps a character prefab id to a complete
    -- replacement objective (docs/objectives.md, "Character overrides"), or to
    -- `false` to hide the row for that character. The replacement must not
    -- restate `optional` (the row slot owns that flag) and must not nest
    -- another override, which would never be consulted.
    if objective.overrides ~= nil then
        Check(row .. " overrides is a table", type(objective.overrides) == "table")
        if type(objective.overrides) == "table" then
            for character, override in pairs(objective.overrides) do
                local where_override = row .. " override " .. tostring(character)
                Check(where_override .. " key is a character prefab id",
                    IsPrefabId(character))
                Check(where_override .. " is an objective table or false",
                    type(override) == "table" or override == false)
                if type(override) == "table" then
                    Check(where_override .. " does not set optional",
                        override.optional == nil)
                    Check(where_override .. " is not nested",
                        override.overrides == nil)
                    -- A tip never completes, so replacing a required row with
                    -- one would silently remove the mission's only gate.
                    Check(where_override .. " tip is only used on optional rows",
                        override.type ~= "tip" or objective.optional == true
                            or objective.type == "tip")
                    ValidateObjectiveFields(where_override, override, 1)
                end
            end
        end
    end

    -- A tip is always optional at runtime (Objectives.IsOptional), so it must
    -- not count as a row that gates completion here either.
    return objective.optional == true or objective.type == "tip"
end

-- `overrides = { <character> = false }` hides a row for that character. Only a
-- hidden *required* row can remove a gate, so check that such a character keeps
-- at least one required row (a mission with none completes instantly).
local function ValidateHiddenRows(where, objectives)
    local hidden_required = {}
    for _, objective in ipairs(objectives or {}) do
        if not Objectives.IsOptional(objective) then
            for character, override in pairs(objective.overrides or {}) do
                if override == false then
                    hidden_required[character] = true
                end
            end
        end
    end

    for character in pairs(hidden_required) do
        local required = 0
        for _, objective in ipairs(objectives or {}) do
            local hidden = objective.overrides ~= nil
                and objective.overrides[character] == false
            if not hidden and not Objectives.IsOptional(objective) then
                required = required + 1
            end
        end
        Check(string.format("%s keeps a required row for %s", where,
            tostring(character)), required > 0)
    end
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
    ValidateHiddenRows(where, mission.objectives)
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
    -- A per-entry repeat override exists for momentary cards that must return
    -- every time. The fired set is still persisted according to the global
    -- mode, so "always" is the only value that stays coherent.
    Check(where .. " frequency is always when set",
        entry.frequency == nil or entry.frequency == "always")

    local function ValidateCondition(name, condition)
        Check(where .. " " .. name .. " is a table", type(condition) == "table")
        if type(condition) ~= "table" then
            return nil, nil
        end
        Check(where .. " " .. name .. " kind is known",
            RealEmergencies.VALID_KINDS[condition.kind] == true)

        if condition.kind == "hounds" then
            Check(where .. " " .. name .. " hound state is known",
                RealEmergencies.VALID_HOUND_STATES[condition.state] == true)
            -- "clear" as a trigger would fire when nothing is happening.
            if name == "trigger" then
                Check(where .. " trigger hound state is not clear",
                    condition.state ~= "clear")
            end
            return nil, nil
        end

        if condition.kind == "cycle" then
            -- A day is a moment, not a way out; it is a trigger only.
            Check(where .. " uses cycle only as a trigger", name == "trigger")
            Check(where .. " cycle day is a positive whole number",
                type(condition.day) == "number" and condition.day >= 1
                    and condition.day % 1 == 0)
            if condition.boss ~= nil then
                Check(where .. " cycle boss is known",
                    RealEmergencies.VALID_BOSSES[condition.boss] == true)
                Check(where .. " cycle boss matches the kill prefab",
                    type(entry.resolve) == "table"
                        and entry.resolve.prefab == condition.boss)
            end
            return nil, nil
        end

        if condition.kind == "kill" then
            -- A death is something that happens while the card is up, so it is
            -- a resolve only; it cannot be the reason a card appears.
            Check(where .. " uses kill only as a resolve", name == "resolve")
            Check(where .. " kill names a prefab id", IsPrefabId(condition.prefab))
            Check(where .. " kill or_gone is a boolean when set",
                condition.or_gone == nil or type(condition.or_gone) == "boolean")
            return nil, nil
        end

        if condition.kind == "ghost" then
            -- "You are a ghost" is a reason a card appears (the death card);
            -- it cannot be a way out.
            Check(where .. " uses ghost only as a trigger", name == "trigger")
            return nil, nil
        end

        if condition.kind == "revived" then
            -- Being alive again is the way out of the death card, so it is a
            -- resolve only.
            Check(where .. " uses revived only as a resolve", name == "resolve")
            return nil, nil
        end

        if condition.kind == "ghost_nearby" then
            Check(where .. " " .. name .. " ghost state is known",
                RealEmergencies.VALID_GHOST_STATES[condition.state] == true)
            -- "clear" as a trigger would fire when nobody is there.
            if name == "trigger" then
                Check(where .. " trigger ghost state is not clear",
                    condition.state ~= "clear")
            end
            return nil, nil
        end

        Check(where .. " " .. name .. " stat is known",
            RealEmergencies.VALID_STATS[condition.stat] == true)

        local operator, value = RealEmergencies.ParseStatThreshold(
            condition.stat, condition.threshold)
        Check(where .. " " .. name .. " threshold parses", operator ~= nil)
        return operator, value
    end

    local trigger_operator, trigger_value =
        ValidateCondition("trigger", entry.trigger)
    local resolve_operator, resolve_value =
        ValidateCondition("resolve", entry.resolve)
    local stat_emergency = type(entry.trigger) == "table"
        and entry.trigger.kind == "stat"
    -- A cycle trigger counts down to a fight, so its card can only end when the
    -- named creature dies; and a kill resolve needs such a trigger to start
    -- from.
    if type(entry.trigger) == "table" and entry.trigger.kind == "cycle" then
        Check(where .. " cycle trigger pairs with a kill resolve",
            type(entry.resolve) == "table" and entry.resolve.kind == "kill")
    end
    if type(entry.resolve) == "table" and entry.resolve.kind == "kill" then
        Check(where .. " kill resolve pairs with a cycle trigger",
            type(entry.trigger) == "table" and entry.trigger.kind == "cycle")
    end
    if type(entry.trigger) == "table" and entry.trigger.kind == "ghost" then
        Check(where .. " ghost trigger pairs with a revived resolve",
            type(entry.resolve) == "table" and entry.resolve.kind == "revived")
    end
    if type(entry.resolve) == "table" and entry.resolve.kind == "revived" then
        Check(where .. " revived resolve pairs with a ghost trigger",
            type(entry.trigger) == "table" and entry.trigger.kind == "ghost")
    end
    if type(entry.trigger) == "table" and entry.trigger.kind == "ghost_nearby" then
        Check(where .. " ghost_nearby trigger pairs with a clear resolve",
            type(entry.resolve) == "table"
                and entry.resolve.kind == "ghost_nearby"
                and entry.resolve.state == "clear")
    end
    if type(entry.resolve) == "table" and entry.resolve.kind == "ghost_nearby" then
        Check(where .. " ghost_nearby resolve pairs with a nearby trigger",
            type(entry.trigger) == "table"
                and entry.trigger.kind == "ghost_nearby"
                and entry.trigger.state == "nearby")
    end
    if stat_emergency then
        Check(where .. " trigger and resolve use the same stat",
            type(entry.resolve) == "table"
                and entry.trigger.stat == entry.resolve.stat)
        if trigger_operator ~= nil and resolve_operator ~= nil then
            local trigger_low =
                trigger_operator == "<" or trigger_operator == "<="
            local resolve_low =
                resolve_operator == "<" or resolve_operator == "<="
            -- Hysteresis needs opposite directions. Low-to-high is the shape for
            -- health/sanity/hunger/freezing; high-to-low for overheating and
            -- wetness, where a high value is the danger.
            Check(where .. " trigger and resolve use opposite comparisons",
                trigger_low ~= resolve_low)
            if trigger_low then
                Check(where .. " resolve is at or above the trigger",
                    resolve_value >= trigger_value)
            else
                Check(where .. " resolve is at or below the trigger",
                    resolve_value <= trigger_value)
            end
        end
    end

    Check(where .. " has an objective list",
        type(entry.objectives) == "table" and #entry.objectives > 0)

    -- Stat emergencies have exactly one required row: the recovery goal. It
    -- must match `resolve`, so the card cannot promise a threshold different
    -- from the one that ends the emergency. Hound and cycle emergencies resolve
    -- on world state, so they have no required row; every row is optional
    -- guidance.
    local required_count = 0
    for j, objective in ipairs(entry.objectives or {}) do
        if not ValidateObjectiveFields(where, objective, j) then
            required_count = required_count + 1
            if stat_emergency then
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
    end
    if stat_emergency then
        Check(where .. " has exactly one required goal row", required_count == 1)
    else
        Check(where .. " has only optional rows", required_count == 0)
    end
    ValidateHiddenRows(where, entry.objectives)
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
        -- Death card. `always`: it must come back on every death even while the
        -- global repeat mode is "session".
        id = "harness_emergency_ghost",
        title = "Harness Emergency Ghost",
        subtext = "You are a ghost.",
        resolved_subtext = "Alive again.",
        frequency = "always",
        trigger = { kind = "ghost" },
        resolve = { kind = "revived" },
        objectives = {
            { type = "tip", icon = "reviver", label = "Ask a friend", optional = true },
        },
    },
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
    {
        -- Day-based trigger with a kill resolve. Day 999 keeps it dormant for
        -- every other fixture; only SetDay(999) arms it.
        id = "harness_emergency_cycle",
        title = "Harness Emergency Cycle",
        subtext = "Something is coming.",
        resolved_subtext = "It is dead.",
        trigger = { kind = "cycle", day = 999 },
        resolve = { kind = "kill", prefab = "harness_monster", or_gone = true },
        objectives = {
            { type = "tip", label = "Prepare for a fight", optional = true },
        },
    },
    {
        -- The living half: a player standing near a dead friend.
        id = "harness_emergency_friend",
        title = "Harness Emergency Friend",
        subtext = "A friend is a ghost.",
        resolved_subtext = "No ghosts nearby.",
        frequency = "always",
        trigger = { kind = "ghost_nearby", state = "nearby" },
        resolve = { kind = "ghost_nearby", state = "clear" },
        objectives = {
            { type = "tip", icon = "reviver", label = "Craft a heart", optional = true },
        },
    },
}
package.loaded["guidedmissions/emergencies"] = {
    entries = SyntheticEmergencies,
    VALID_STATS = RealEmergencies.VALID_STATS,
    VALID_KINDS = RealEmergencies.VALID_KINDS,
    IsGhost = RealEmergencies.IsGhost,
    CanTriggerWhileGhost = RealEmergencies.CanTriggerWhileGhost,
    GetStatFraction = RealEmergencies.GetStatFraction,
    GetStatValue = RealEmergencies.GetStatValue,
    ParseThreshold = RealEmergencies.ParseThreshold,
    ParseStatThreshold = RealEmergencies.ParseStatThreshold,
    IsTriggered = RealEmergencies.IsTriggered,
    IsResolved = RealEmergencies.IsResolved,
    NewState = RealEmergencies.NewState,
    NoteEvent = RealEmergencies.NoteEvent,
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
    AllPlayers[#AllPlayers + 1] = player
    local fixture_manager = Manager(player)
    Advance(1)
    return fixture_manager, player
end

-- Point a fixture manager at a mission defined in the test, with progress
-- seeded exactly as `SetMission` would.
local function Activate(fixture_manager, player, mission)
    fixture_manager.current_mission = mission
    fixture_manager.completed = false
    -- Mirror SetMission: resolve character overrides once, then seed progress
    -- from the rows this player actually has.
    fixture_manager.objectives = Objectives.ResolveAll(
        mission.objectives, player.prefab)
    fixture_manager.progress = {}
    for i, objective in ipairs(fixture_manager.objectives) do
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

local function SetHunger(player, current, max)
    player.components.hunger = { current = current, max = max or 100 }
end

-- The game component is `moisture`; "wetness" is the objective-facing name.
local function SetWetness(player, current, max)
    player.components.moisture = { moisture = current, maxmoisture = max or 100 }
end

-- Temperature is a raw degree reading, not a percentage.
local function SetTemperature(player, current)
    player.components.temperature = { current = current }
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

-- `reach_stat`/emergency thresholds are parsed in the stat's own units, so
-- temperature accepts negative degrees and goes above 100.
local function StatParses(stat, text, operator, value)
    local op, val = RealEmergencies.ParseStatThreshold(stat, text)
    return op == operator and val == value
end
Check("temperature accepts a negative threshold",
    StatParses("temperature", "<0", "<", 0))
Check("temperature accepts a threshold above 100",
    StatParses("temperature", ">110", ">", 110))
Check("temperature rejects values outside its range",
    RealEmergencies.ParseStatThreshold("temperature", "<-101") == nil
        and RealEmergencies.ParseStatThreshold("temperature", ">201") == nil)
Check("wetness uses the percentage range",
    StatParses("wetness", ">50", ">", 50)
        and RealEmergencies.ParseStatThreshold("wetness", "<101") == nil)

-- Stat reads use raw fields, not GetPercent (which sanity masks).
local stat_player = NewInst(3001)
SetHealth(stat_player, 40, 100)
Check("health fraction uses current/max",
    math.abs(RealEmergencies.GetStatFraction(stat_player, "health") - 0.4) < 0.0001)
SetSanity(stat_player, 25, 50)
Check("sanity fraction uses current/max",
    math.abs(RealEmergencies.GetStatFraction(stat_player, "sanity") - 0.5) < 0.0001)
SetHunger(stat_player, 30, 100)
Check("hunger fraction uses current/max",
    math.abs(RealEmergencies.GetStatFraction(stat_player, "hunger") - 0.3) < 0.0001)
SetWetness(stat_player, 60, 100)
Check("wetness fraction uses moisture/maxmoisture",
    math.abs(RealEmergencies.GetStatFraction(stat_player, "wetness") - 0.6) < 0.0001)
SetTemperature(stat_player, -5)
Check("temperature reads raw degrees",
    RealEmergencies.GetStatValue(stat_player, "temperature") == -5)
Check("temperature has no fraction",
    RealEmergencies.GetStatFraction(stat_player, "temperature") == nil)
Check("missing stat fraction is nil",
    RealEmergencies.GetStatFraction(NewInst(3002), "health") == nil)
Check("missing hunger fraction is nil",
    RealEmergencies.GetStatFraction(NewInst(3002), "hunger") == nil)
Check("missing wetness value is nil",
    RealEmergencies.GetStatValue(NewInst(3002), "wetness") == nil)
Check("missing temperature value is nil",
    RealEmergencies.GetStatValue(NewInst(3002), "temperature") == nil)
Check("unknown stat fraction is nil",
    RealEmergencies.GetStatFraction(stat_player, "mightiness") == nil)

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

-- Temperature thresholds are raw degrees, so freezing is a low threshold and
-- overheating a high one.
local freezing_entry = {
    trigger = { kind = "stat", stat = "temperature", threshold = "<0" },
}
local temperature_player = NewInst(3004)
SetTemperature(temperature_player, -5)
Check("temperature below zero triggers freezing",
    RealEmergencies.IsTriggered(freezing_entry, temperature_player))
SetTemperature(temperature_player, 5)
Check("temperature above zero does not trigger freezing",
    not RealEmergencies.IsTriggered(freezing_entry, temperature_player))

-- Hound-wave conditions: warning and spawn-in are world state, and "clear"
-- also requires no living wave hound near the player.
local hound_world = { warning = true, attacking = false }
TheWorld.components = {
    hounded = {
        GetWarning = function() return hound_world.warning end,
        GetAttacking = function() return hound_world.attacking end,
    },
}
local hound_entry = {
    trigger = { kind = "hounds", state = "warning" },
    resolve = { kind = "hounds", state = "clear" },
}
local hound_player = NewInst(3100)
Check("hound warning triggers",
    RealEmergencies.IsTriggered(hound_entry, hound_player))
Check("hound warning is not clear",
    not RealEmergencies.IsResolved(hound_entry, hound_player))

hound_world.warning = false
hound_world.attacking = true
Check("hound spawning is not clear",
    not RealEmergencies.IsResolved(hound_entry, hound_player))

hound_world.attacking = false
Check("no warning, no spawn and no hound is clear",
    RealEmergencies.IsResolved(hound_entry, hound_player))

-- The proximity scan calls `HasTag`, so give the fixtures the entity method
-- rather than teaching the mod to read the test's `tags` table.
local function StubHound(x, z, tags)
    local entity = { prefab = "hound", x = x, z = z, tags = tags }
    function entity:HasTag(tag)
        return self.tags[tag] == true
    end
    return entity
end

TheSim.entities = { StubHound(0, 0, { hound = true }) }
Check("a nearby wave hound keeps the card open",
    not RealEmergencies.IsResolved(hound_entry, hound_player))

TheSim.entities = { StubHound(0, 0, { hound = true, pet_hound = true }) }
Check("a pet hound does not keep the card open",
    RealEmergencies.IsResolved(hound_entry, hound_player))

TheSim.entities = { StubHound(999, 0, { hound = true }) }
Check("a distant hound does not keep the card open",
    RealEmergencies.IsResolved(hound_entry, hound_player))

local dead_hound = StubHound(0, 0, { hound = true })
dead_hound.components = { health = { IsDead = function() return true end } }
TheSim.entities = { dead_hound }
Check("a dead hound does not keep the card open",
    RealEmergencies.IsResolved(hound_entry, hound_player))

TheSim.entities = {}
TheWorld.components = nil

-- Scoped so these fixtures do not add to the main chunk's 200-local limit.
do
    -- Cycle trigger and kill resolve, at the condition level first. The day is the
    -- 1-based number the HUD shows (cycles + 1); a kill is a death of the named
    -- prefab while the card is up, whoever caused it.
    local cycle_entry = {
        trigger = { kind = "cycle", day = 3 },
        resolve = { kind = "kill", prefab = "deerclops" },
    }
    TheWorld.state.cycles = 2
    Check("cycle trigger fires on its day",
        RealEmergencies.IsTriggered(cycle_entry, hound_player))
    TheWorld.state.cycles = 3
    Check("cycle trigger does not fire late",
        not RealEmergencies.IsTriggered(cycle_entry, hound_player))
    Check("a malformed cycle day never triggers",
        not RealEmergencies.IsTriggered(
            { trigger = { kind = "cycle", day = "three" } }, hound_player))
    
    local kill_state = RealEmergencies.NewState()
    Check("kill resolve is false before any death",
        not RealEmergencies.IsResolved(cycle_entry, hound_player, kill_state))
    RealEmergencies.NoteEvent(kill_state, "entity_death", { inst = { prefab = "hound" } })
    Check("an unrelated death does not resolve",
        not RealEmergencies.IsResolved(cycle_entry, hound_player, kill_state))
    RealEmergencies.NoteEvent(kill_state, "entity_death", {
        inst = { prefab = "deerclops" },
        afflicter = { prefab = "tentacle" },
    })
    Check("a death by any killer resolves",
        RealEmergencies.IsResolved(cycle_entry, hound_player, kill_state))
    Check("kill resolve without state is false",
        not RealEmergencies.IsResolved(cycle_entry, hound_player))
    
    -- A `boss` guard suppresses the whole trigger when that boss cannot appear in
    -- this world. The "Never" setting flips TUNING.SPAWN_DEERCLOPS at world
    -- creation, and the spawner component only exists on the forest shard.
    local boss_entry = { trigger = { kind = "cycle", day = 3, boss = "deerclops" } }
    TUNING = { SPAWN_DEERCLOPS = true, DEERCLOPS_ATTACKS_PER_SEASON = 4 }
    TheWorld.components = { deerclopsspawner = {} }
    TheWorld.state.cycles = 2
    Check("cycle boss guard passes when the boss is enabled",
        RealEmergencies.IsTriggered(boss_entry, hound_player))
    TUNING.SPAWN_DEERCLOPS = false
    Check("cycle boss guard blocks a disabled boss",
        not RealEmergencies.IsTriggered(boss_entry, hound_player))
    TUNING.SPAWN_DEERCLOPS = true
    TUNING.DEERCLOPS_ATTACKS_PER_SEASON = 0
    Check("cycle boss guard blocks a zeroed attack rate",
        not RealEmergencies.IsTriggered(boss_entry, hound_player))
    TUNING.DEERCLOPS_ATTACKS_PER_SEASON = 4
    TheWorld.components = nil
    Check("cycle boss guard blocks a shard without the spawner",
        not RealEmergencies.IsTriggered(boss_entry, hound_player))
    Check("an unknown boss guard never fires",
        not RealEmergencies.IsTriggered(
            { trigger = { kind = "cycle", day = 3, boss = "bearger" } }, hound_player))
    TUNING = nil
    TheWorld.state.cycles = 0
    
    -- `or_gone` adds "the boss left/despawned" to a kill resolve. The payload of
    -- `hasslerremoved` is the entity itself, unlike `entity_death`.
    local gone_entry = {
        resolve = { kind = "kill", prefab = "deerclops", or_gone = true },
    }
    local gone_state = RealEmergencies.NewState()
    RealEmergencies.NoteEvent(gone_state, "hasslerremoved", { prefab = "deerclops" })
    Check("a boss removal resolves an or_gone kill",
        RealEmergencies.IsResolved(gone_entry, hound_player, gone_state))
    Check("a boss removal does not resolve a plain kill",
        not RealEmergencies.IsResolved(cycle_entry, hound_player, gone_state))
    local other_boss_state = RealEmergencies.NewState()
    RealEmergencies.NoteEvent(other_boss_state, "hasslerremoved", { prefab = "bearger" })
    Check("an unrelated boss removal does not resolve",
        not RealEmergencies.IsResolved(gone_entry, hound_player, other_boss_state))
    
    -- The same pair through the manager: the world-state watcher pops the card on
    -- the day, and the world's `entity_death` event resolves it.
    local cycle_manager, cycle_player = Spawn()
    SetDay(cycle_player, 999)
    Check("cycle card pops at the start of its day",
        Read(cycle_player)["guidedmissions.title"] == "Harness Emergency Cycle")
    Check("cycle card state", State(cycle_player) == "emergency")
    Check("cycle card carries only optional rows", Row(cycle_player, 1)[5] == "1")
    
    cycle_player:Fire("entity_death", { inst = { prefab = "hound" } })
    Check("an unrelated death keeps the cycle card up", State(cycle_player) == "emergency")
    cycle_player:Fire("entity_death", {
        inst = { prefab = "harness_monster" },
        afflicter = { prefab = "hound" },
    })
    Check("the named death resolves the cycle card", State(cycle_player) == "won")
    TheWorld.state.cycles = 0
    Advance(3)
    Check("chain restored after a cycle emergency",
        Read(cycle_player)["guidedmissions.title"] == "Harness First")
    
    -- State is scoped to one showing: a death before the card appears is not a kill
    -- the player saw go down, so it cannot resolve it.
    local late_manager, late_player = Spawn()
    late_player:Fire("entity_death", { inst = { prefab = "harness_monster" } })
    SetDay(late_player, 999)
    Check("a death from before the card does not resolve it",
        State(late_player) == "emergency")
    -- `or_gone` also resolves when the boss is removed (left, despawned, or
    -- removed): the `hasslerremoved` payload is the entity, not a data table.
    late_player:Fire("hasslerremoved", { prefab = "harness_monster" })
    Check("a boss removal resolves the cycle card", State(late_player) == "won")
    TheWorld.state.cycles = 0
end

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

-- Only a resolved card counts as seen. A save taken while the card is still
-- up must not suppress the entry: a relog before it resolves gets the card
-- again, even in "server" mode.
local interrupted_save = server_manager:OnSave()
Check("an unresolved emergency is not saved as fired",
    interrupted_save.fired_emergencies == nil
        or interrupted_save.fired_emergencies["harness_emergency_health"] == nil)

SetHealth(server_player, 80, 100)
server_player:Fire("healthdelta", { oldpercent = 0.4, newpercent = 0.8, amount = 40 })
Check("server mode resolves", State(server_player) == "won")

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
Check("save mid-emergency stores a session fired set",
    type(save_data.fired_emergencies) == "table"
        and next(save_data.fired_emergencies) == nil)

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

-- "session" carries the fired set through the save so a shard transfer keeps
-- it (a caves trip is still the same session), while a fresh join re-arms.
Settings.emergency_frequency = "session"
local session_manager, session_player = Spawn()
SetHealth(session_player, 40, 100)
session_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("session test emergency active", State(session_player) == "emergency")
SetHealth(session_player, 80, 100)
session_player:Fire("healthdelta", { oldpercent = 0.4, newpercent = 0.8, amount = 40 })
Advance(3)
Check("session test resolved",
    session_manager.fired_emergencies["harness_emergency_health"] == true)
local session_save = session_manager:OnSave()
Check("session save stores the fired set",
    type(session_save.fired_emergencies) == "table"
        and session_save.fired_emergencies["harness_emergency_health"] == true)

-- A live shard migration is not a new session: `inst.migration` is what
-- player_common's OnPreLoad sets before the component loads, and the record
-- names the source shard's world session -- which is the same value OnSave
-- stamped into the save (`world_session`). `worldid` is the *other* shard.
Check("save stamps the writing world session",
    session_save.world_session == TheWorld.meta.session_identifier)
local migrated_inst = NewInst(4003)
SetHealth(migrated_inst, 100, 100)
migrated_inst.migration = {
    worldid = "HARNESS_OTHER_SHARD",
    sessionid = TheWorld.meta.session_identifier,
}
Netvars.Attach(migrated_inst)
local migrated_manager = Manager(migrated_inst)
migrated_manager:OnLoad(session_save)
Advance(1)
Check("a migration restores the fired set",
    migrated_manager.fired_emergencies["harness_emergency_health"] == true)
SetHealth(migrated_inst, 40, 100)
migrated_inst:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("a shard migration suppresses a repeat",
    Read(migrated_inst)["guidedmissions.title"] == "Harness First")

-- A save file can carry a *stale* migration payload. player_common writes
-- `inst.migration` into the save, and playerspawner clears it only when it
-- spawns the player -- so an entity that loaded but never spawned (a client
-- rejected at the mod handshake, say) keeps it on disk. That record was written
-- by a different shard than the one it names, so it is not a live transfer.
local stale_inst = NewInst(4005)
SetHealth(stale_inst, 100, 100)
stale_inst.migration = {
    worldid = "HARNESS_OTHER_SHARD",
    sessionid = "SOME_PREVIOUS_SESSION",
}
Netvars.Attach(stale_inst)
local stale_manager = Manager(stale_inst)
stale_manager:OnLoad(session_save)
Advance(1)
Check("a stale migration record starts a new session",
    next(stale_manager.fired_emergencies) == nil)
SetHealth(stale_inst, 40, 100)
stale_inst:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("a stale migration record re-arms the emergency",
    Read(stale_inst)["guidedmissions.title"] == "Harness Emergency Health")

-- A failed transfer can leave a record naming this very shard. The player is
-- being restored where it was leaving, which is a relog, not a continuation.
local failed_inst = NewInst(4006)
SetHealth(failed_inst, 100, 100)
failed_inst.migration = {
    worldid = TheShard:GetShardId(),
    sessionid = TheWorld.meta.session_identifier,
}
Netvars.Attach(failed_inst)
local failed_manager = Manager(failed_inst)
failed_manager:OnLoad(session_save)
Advance(1)
Check("a record naming this shard is not a live migration",
    next(failed_manager.fired_emergencies) == nil)

-- The same save loaded by a fresh join starts a new session and re-arms.
local rejoined_inst = NewInst(4004)
SetHealth(rejoined_inst, 100, 100)
Netvars.Attach(rejoined_inst)
local rejoined_manager = Manager(rejoined_inst)
rejoined_manager:OnLoad(session_save)
Advance(1)
Check("a fresh join clears the fired set",
    next(rejoined_manager.fired_emergencies) == nil)
SetHealth(rejoined_inst, 40, 100)
rejoined_inst:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("a fresh join re-arms the session emergency",
    Read(rejoined_inst)["guidedmissions.title"] == "Harness Emergency Health")

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

-- A card interrupted before it resolves was never "won", so it was never
-- marked as seen: the same trigger pops it again.
Check("an interrupted emergency was not marked fired",
    jump_manager.fired_emergencies["harness_emergency_health"] == nil)
jump_player:Fire("healthdelta", { oldpercent = 0.4, newpercent = 0.4, amount = 0 })
Check("an interrupted emergency can fire again", State(jump_player) == "emergency")
jump_manager:JumpTo(2)

jump_manager.fired_emergencies["harness_emergency_health"] = true
jump_manager:JumpTo(2)
Check("a jump keeps the fired set",
    jump_manager.fired_emergencies["harness_emergency_health"] == true)
jump_manager:Reset()
Check("reset clears the fired set",
    next(jump_manager.fired_emergencies) == nil)

-- Hound emergency end-to-end: the `houndwarning` event pops the card at the
-- first bark, and the poll closes it once the wave is clear. A dedicated entry
-- table keeps the shared synthetic fixtures on their stat emergencies.
local hound_emergency = {
    id = "harness_emergency_hounds",
    title = "Harness Hounds",
    subtext = "Barking.",
    resolved_subtext = "Quiet.",
    trigger = { kind = "hounds", state = "warning" },
    resolve = { kind = "hounds", state = "clear" },
    objectives = {
        { type = "kill", prefab = "hound", count = 1, label = "Kill a hound", optional = true },
    },
}
local hound_manager, hound_fixture = Spawn()
local hound_emergencies = package.loaded["guidedmissions/emergencies"]
local saved_entries = hound_emergencies.entries
hound_emergencies.entries = { hound_emergency }
local hound_flags = { warning = true, attacking = false }
TheWorld.components = {
    hounded = {
        GetWarning = function() return hound_flags.warning end,
        GetAttacking = function() return hound_flags.attacking end,
    },
}
hound_fixture:Fire("houndwarning", 0)
Check("houndwarning pops the hound emergency",
    State(hound_fixture) == "emergency")
Check("hound emergency suspends the chain",
    hound_manager.suspended_mission == SyntheticMissions[1])
hound_flags.warning = false
hound_manager:CheckEmergencies()
Check("a clear wave shows the recovered card", State(hound_fixture) == "won")
Check("the recovered card uses resolved_subtext",
    Read(hound_fixture)["guidedmissions.subtext"] == "Quiet.")
TheWorld.components = nil
hound_emergencies.entries = saved_entries
Advance(3)
Check("chain restored after the hound emergency",
    Read(hound_fixture)["guidedmissions.title"] == "Harness First")

-- Hunger uses the same stat machinery; its component pushes `hungerdelta` from
-- the 1 Hz decay task. A dedicated entry keeps the shared fixtures unchanged.
local hunger_emergency = {
    id = "harness_emergency_hunger",
    title = "Harness Hunger",
    subtext = "Empty.",
    resolved_subtext = "Fed.",
    trigger = { kind = "stat", stat = "hunger", threshold = "<25" },
    resolve = { kind = "stat", stat = "hunger", threshold = ">=50" },
    objectives = {
        { type = "reach_stat", stat = "hunger", threshold = ">=50",
          label = "Get hunger back to 50%" },
        { type = "eat", prefab = "berries", count = 1,
          label = "Eat berries", optional = true },
    },
}
local hunger_manager, hunger_player = Spawn()
local hunger_emergencies = package.loaded["guidedmissions/emergencies"]
local saved_hunger_entries = hunger_emergencies.entries
hunger_emergencies.entries = { hunger_emergency }
SetHunger(hunger_player, 40, 100)
hunger_player:Fire("hungerdelta", { oldpercent = 1, newpercent = 0.4, delta = -60 })
Check("40% hunger is not low enough to trigger", State(hunger_player) == "active")
SetHunger(hunger_player, 20, 100)
hunger_player:Fire("hungerdelta", { oldpercent = 0.4, newpercent = 0.2, delta = -20 })
Check("low hunger pops the emergency", State(hunger_player) == "emergency")
Check("hunger goal row is live", Row(hunger_player, 1)[3] == "20/50%")
SetHunger(hunger_player, 60, 100)
hunger_player:Fire("hungerdelta", { oldpercent = 0.2, newpercent = 0.6, delta = 40 })
Check("a fed player shows the recovered card", State(hunger_player) == "won")
Check("hunger recovered card subtext",
    Read(hunger_player)["guidedmissions.subtext"] == "Fed.")
hunger_emergencies.entries = saved_hunger_entries
Advance(3)
Check("chain restored after the hunger emergency",
    Read(hunger_player)["guidedmissions.title"] == "Harness First")

-- Wetness is high-is-bad (trigger >50, resolve <=20). Its component pushes
-- `moisturedelta` every frame, so the manager reads it on the 1 Hz poll.
local wet_emergency = {
    id = "harness_emergency_wet",
    title = "Harness Wet",
    subtext = "Soaked.",
    resolved_subtext = "Dry.",
    trigger = { kind = "stat", stat = "wetness", threshold = ">50" },
    resolve = { kind = "stat", stat = "wetness", threshold = "<=20" },
    objectives = {
        { type = "reach_stat", stat = "wetness", threshold = "<=20",
          label = "Dry off to 20%" },
    },
}
local wet_manager, wet_player = Spawn()
local wet_emergencies = package.loaded["guidedmissions/emergencies"]
local saved_wet_entries = wet_emergencies.entries
wet_emergencies.entries = { wet_emergency }
SetWetness(wet_player, 60, 100)
Advance(1)
Check("60% wetness pops the emergency", State(wet_player) == "emergency")
Check("wetness goal row is live", Row(wet_player, 1)[3] == "60/20%")
SetWetness(wet_player, 10, 100)
Advance(1)
Check("drying off shows the recovered card", State(wet_player) == "won")
wet_emergencies.entries = saved_wet_entries
Advance(3)
Check("chain restored after the wetness emergency",
    Read(wet_player)["guidedmissions.title"] == "Harness First")

-- Temperature is in degrees. Overheating is high-is-bad (trigger >70,
-- resolve <=50); the same machinery handles freezing with a low threshold.
local heat_emergency = {
    id = "harness_emergency_heat",
    title = "Harness Heat",
    subtext = "Hot.",
    resolved_subtext = "Cool.",
    trigger = { kind = "stat", stat = "temperature", threshold = ">70" },
    resolve = { kind = "stat", stat = "temperature", threshold = "<=50" },
    objectives = {
        { type = "reach_stat", stat = "temperature", threshold = "<=50",
          label = "Cool down to 50°" },
    },
}
local heat_manager, heat_player = Spawn()
local heat_emergencies = package.loaded["guidedmissions/emergencies"]
local saved_heat_entries = heat_emergencies.entries
heat_emergencies.entries = { heat_emergency }
SetTemperature(heat_player, 80)
Advance(1)
Check("80 degrees pops the overheating emergency",
    State(heat_player) == "emergency")
Check("temperature goal row uses degrees",
    Row(heat_player, 1)[3] == "80/50°")
SetTemperature(heat_player, 40)
Advance(1)
Check("cooling off shows the recovered card", State(heat_player) == "won")
heat_emergencies.entries = saved_heat_entries
Advance(3)
Check("chain restored after the overheating emergency",
    Read(heat_player)["guidedmissions.title"] == "Harness First")

-- No trigger during the chain's won hold or after the chain is complete.
local hold_manager, hold_player = Spawn()
hold_manager.progress[1] = 3
hold_manager:CheckCompletion()
Check("chain hold active", State(hold_player) == "won")
SetHealth(hold_player, 40, 100)
hold_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("no emergency during the chain hold", State(hold_player) == "won")

-- Emergencies fire whenever they apply, including after the chain is finished.
-- The overlay replaces the all-complete card and Sync puts it back on resolve.
local done_manager, done_player = Spawn()
done_manager:JumpTo(#SyntheticMissions + 1)
SetHealth(done_player, 40, 100)
done_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("an emergency fires after chain completion", State(done_player) == "emergency")
SetHealth(done_player, 80, 100)
done_player:Fire("healthdelta", { oldpercent = 0.4, newpercent = 0.8, amount = 40 })
Check("the standalone emergency resolves", State(done_player) == "won")
Advance(3)
Check("the all-complete card is restored", State(done_player) == "done")
Check("the restored card is the finished card",
    Read(done_player)["guidedmissions.title"] == "All Missions Complete")

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

-- ---- ghost, revival and the helper card ---------------------------------
--
-- Ghost state is the `playerghost` tag. Health is neutralised to 50 while a
-- ghost, so the manager must not use IsDead() to spot one.

-- Becoming a ghost pops the death card; the tag clearing resolves it.
local ghost_manager, ghost_player = Spawn()
SetHealth(ghost_player, 50, 100)
ghost_player:AddTag("playerghost")
ghost_player:Fire("ms_becameghost")
Check("becoming a ghost pops the death card", State(ghost_player) == "emergency")
Check("death card title", Read(ghost_player)["guidedmissions.title"]
    == "Harness Emergency Ghost")
ghost_player:RemoveTag("playerghost")
ghost_player:Fire("ms_respawnedfromghost")
Check("revival resolves the death card", State(ghost_player) == "won")
Advance(3)
Check("chain restored after the death card",
    Read(ghost_player)["guidedmissions.title"] == "Harness First")

-- A death supersedes an active card: a stat card is not actionable while dead.
local preempt_manager, preempt_player = Spawn()
SetHealth(preempt_player, 40, 100)
preempt_player:Fire("healthdelta", { oldpercent = 0.9, newpercent = 0.4, amount = -50 })
Check("stat card up before the death", Read(preempt_player)["guidedmissions.title"]
    == "Harness Emergency Health")
SetHealth(preempt_player, 50, 100)
preempt_player:AddTag("playerghost")
preempt_player:Fire("ms_becameghost")
Check("death preempts the stat card", Read(preempt_player)["guidedmissions.title"]
    == "Harness Emergency Ghost")
Check("the preempted card was not marked fired",
    preempt_manager.fired_emergencies["harness_emergency_health"] == nil)
preempt_player:RemoveTag("playerghost")
preempt_player:Fire("ms_respawnedfromghost")
Advance(3)

-- While a ghost, only the death card is eligible; a low health reading must not
-- fire the stat card.
local elig_manager, elig_player = Spawn()
SetHealth(elig_player, 10, 100)
elig_player:AddTag("playerghost")
elig_player:Fire("ms_becameghost")
Check("a ghost gets the death card, never a stat card",
    Read(elig_player)["guidedmissions.title"] == "Harness Emergency Ghost")
elig_player:RemoveTag("playerghost")
elig_player:Fire("ms_respawnedfromghost")
Advance(3)

-- The death card is `frequency = "always"`: it returns on a second death even
-- while the global mode is "session".
ghost_player:AddTag("playerghost")
ghost_player:Fire("ms_becameghost")
Check("the death card returns on a second death", State(ghost_player) == "emergency")
ghost_player:RemoveTag("playerghost")
ghost_player:Fire("ms_respawnedfromghost")
Advance(3)

-- The helper card: a living player standing near a ghost friend. The trigger
-- radius is 20 and the clear radius 25 (room for a drifting ghost).
local friend_manager, friend_player = Spawn()
local ghost_stub = {
    prefab = "wilson", x = 0, z = 4,
    tags = { playerghost = true },
    IsValid = function() return true end,
}
TheSim.entities[#TheSim.entities + 1] = ghost_stub
Advance(1)
Check("the helper card pops near a ghost", State(friend_player) == "emergency")
Check("helper card title", Read(friend_player)["guidedmissions.title"]
    == "Harness Emergency Friend")
ghost_stub.x = 999
Advance(1)
Check("the helper card clears when the ghost leaves", State(friend_player) == "won")
table.remove(TheSim.entities)
Advance(3)
Check("chain restored after the helper card",
    Read(friend_player)["guidedmissions.title"] == "Harness First")

-- `when` gates a row on a world setting. The row is dropped server-side, so the
-- client never sees a row that cannot apply.
local gate_manager, gate_player = Spawn()
Activate(gate_manager, gate_player, {
    id = "fixture_when",
    title = "Gated",
    subtext = "One row is gated.",
    objectives = {
        { type = "collect", prefab = "flint", count = 1, label = "Collect flint" },
        { type = "tip", icon = "log", label = "Portal only", optional = true,
          when = { setting = "portal_rez" } },
    },
})
Check("a gated row is hidden without the setting", Row(gate_player, 2)[1] == nil)
TheWorld.components = { worldsettings = { GetSetting = function(_, name)
    return name == "portal_rez" and true or nil
end } }
gate_manager:Sync()
Check("a gated row appears with the setting", Row(gate_player, 2)[1] == "Portal only")
TheWorld.components.worldsettings.GetSetting = function() return nil end
gate_manager:Sync()
Check("a gated row hides again when the setting clears", Row(gate_player, 2)[1] == nil)
TheWorld.components = nil

-- ---- multiplayer mode (shared build rows) --------------------------------
--
-- A `shared` build row is satisfied by an equivalent structure already standing
-- nearby when Multiplayer Mode is on. The manager rereads it through
-- Objectives.LiveProgress from InitialProgress (mission start) and the 1-second
-- poll, so these drive the real manager; no shared or cross-player state exists.

local function Place(prefab, x, z)
    TheSim.entities[#TheSim.entities + 1] = {
        prefab = prefab,
        x = x or 0,
        z = z or 0,
        tags = { structure = true },
    }
end

local function SharedBuildMission(count)
    return {
        id = "harness_shared_build",
        title = "Shared Base",
        subtext = "Someone already built it.",
        objectives = {
            { type = "build", prefab = "firepit", count = count or 1,
              label = "Build a Fire Pit", shared = true },
        },
    }
end

local saved_multiplayer_mode = Settings.multiplayer_mode

-- Option off: a nearby structure is ignored, exactly as before this feature.
Settings.multiplayer_mode = false
TheSim.entities = {}
Place("firepit")
local mp_off_manager, mp_off_player = Spawn()
Activate(mp_off_manager, mp_off_player, SharedBuildMission(1))
Check("shared build ignores a nearby structure with the option off",
    Row(mp_off_player, 1)[3] == "0/1")
Advance(1)
Check("shared build stays unchecked with the option off",
    State(mp_off_player) == "active" and Row(mp_off_player, 1)[4] == "0")

-- Option on, nothing nearby: the row waits for a structure like any build row.
Settings.multiplayer_mode = true
TheSim.entities = {}
local mp_empty_manager, mp_empty_player = Spawn()
Activate(mp_empty_manager, mp_empty_player, SharedBuildMission(1))
Check("shared build does not count with nothing nearby",
    Row(mp_empty_player, 1)[3] == "0/1")
Advance(1)
Check("shared build stays active with nothing nearby",
    State(mp_empty_player) == "active")

-- Structure present at mission start: InitialProgress seeds the row done.
Place("firepit")
local mp_start_manager, mp_start_player = Spawn()
Activate(mp_start_manager, mp_start_player, SharedBuildMission(1))
Check("shared build counts at mission start", Row(mp_start_player, 1)[3] == "1/1")
Check("shared build row renders done at mission start",
    Row(mp_start_player, 1)[4] == "1")

-- A different structure, or one without the `structure` tag, does not count.
TheSim.entities = {}
Place("researchlab")
local mp_other_manager, mp_other_player = Spawn()
Activate(mp_other_manager, mp_other_player, SharedBuildMission(1))
Check("shared build ignores a different structure",
    Row(mp_other_player, 1)[3] == "0/1")

TheSim.entities = {}
TheSim.entities[1] = { prefab = "firepit", x = 0, z = 0, tags = {} }
local mp_tag_manager, mp_tag_player = Spawn()
Activate(mp_tag_manager, mp_tag_player, SharedBuildMission(1))
Check("shared build ignores untagged entities",
    Row(mp_tag_player, 1)[3] == "0/1")

-- Progress caps at the target: two copies do not render 2/1.
TheSim.entities = {}
Place("firepit")
Place("firepit", 5, 5)
local mp_cap_manager, mp_cap_player = Spawn()
Activate(mp_cap_manager, mp_cap_player, SharedBuildMission(1))
Check("shared build caps progress at the target",
    Row(mp_cap_player, 1)[3] == "1/1")

-- Structure appears mid-mission: the poll ticks the row and completes the
-- mission through the usual `won` card and chat announcement.
TheSim.entities = {}
local mp_later_manager, mp_later_player = Spawn()
Activate(mp_later_manager, mp_later_player, SharedBuildMission(1))
Check("shared build waits for a teammate to build",
    Row(mp_later_player, 1)[3] == "0/1")
Place("firepit", 10, 10)
Advance(1)
Check("shared build ticks when a structure appears nearby",
    Row(mp_later_player, 1)[3] == "1/1")
Check("shared build completes the mission", State(mp_later_player) == "won")
Check("shared build completion uses the normal card",
    Read(mp_later_player)["guidedmissions.title"] == "Shared Base")
Check("shared build completion is announced",
    announcements[#announcements] == "Wilson completed: Shared Base")
Advance(3)

-- Sticky: leaving range never removes credit already earned.
TheSim.entities = {}
Place("firepit")
local mp_sticky_manager, mp_sticky_player = Spawn()
Activate(mp_sticky_manager, mp_sticky_player, SharedBuildMission(2))
Check("shared build counts the nearby structure",
    Row(mp_sticky_player, 1)[3] == "1/2")
TheSim.entities[1].x = 1000
Advance(1)
Check("shared build keeps its progress after leaving range",
    Row(mp_sticky_player, 1)[3] == "1/2")

-- Restore the shared settings and world for the fixtures below.
Settings.multiplayer_mode = saved_multiplayer_mode
TheSim.entities = {}

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

    -- An item already carried satisfies the row without a duplicate craft: it
    -- may have been crafted before the mission started or handed over.
    local held_manager, held_player = Spawn()
    Carry(held_player, "axe", 1)
    Activate(held_manager, held_player, {
        id = "fixture_craft_held",
        title = "Craft",
        subtext = "Make it.",
        objectives = {
            { type = "craft", prefab = "axe", count = 1, label = "Craft an axe" },
        },
    })
    Check("craft counts starting inventory", Row(held_player, 1)[3] == "1/1")
    held_manager:CheckCompletion()
    Check("craft completes from starting inventory", State(held_player) == "won")

    -- And the same row completes when the item arrives mid-mission without a
    -- `builditem` event (picked up, found, or given).
    local got_manager, got_player = Spawn()
    Activate(got_manager, got_player, {
        id = "fixture_craft_pickup",
        title = "Craft",
        subtext = "Make it.",
        objectives = {
            { type = "craft", prefab = "axe", count = 1, label = "Craft an axe" },
        },
    })
    Carry(got_player, "axe", 1)
    InventoryChanged(got_player)
    Check("craft completes from a carried item", State(got_player) == "won")
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

type_fixtures.deploy = function()
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_deploy",
        title = "Green Thumb",
        subtext = "Dirt, seeds, patience.",
        objectives = {
            { type = "deploy", prefab = "farm_plow_item", count = 1, label = "Use a Garden Digamajig" },
        },
    })
    Check("deploy label is rendered", Row(player, 1)[1] == "Use a Garden Digamajig")
    Check("deploy icon is the prefab", Row(player, 1)[2] == "farm_plow_item")

    -- Crafting it, or building a structure, is not deploying it.
    player:Fire("builditem", Build("farm_plow_item"))
    Check("deploy ignores builditem", State(player) == "active")
    -- Vanilla pushes `deployitem` on the deployer with the item's prefab
    -- (`components/deployable.lua:142`), after `ondeploy` may have removed it.
    player:Fire("deployitem", { prefab = "birdtrap" })
    Check("deploy filters other items", State(player) == "active")
    player:Fire("deployitem", { prefab = "farm_plow_item" })
    Check("deploy completes on deployitem", State(player) == "won")

    -- Without a prefab any deployed item counts; `icon` names the row art
    -- because an unfiltered row has no single item.
    local any_manager, any_player = Spawn()
    Activate(any_manager, any_player, {
        id = "fixture_deploy_any",
        title = "Put It Down",
        subtext = "Somewhere useful.",
        objectives = {
            { type = "deploy", count = 2, icon = "birdtrap", label = "Deploy items" },
        },
    })
    Check("unfiltered deploy uses the icon override", Row(any_player, 1)[2] == "birdtrap")
    any_player:Fire("deployitem", { prefab = "birdtrap" })
    Check("unfiltered deploy counts any item", Row(any_player, 1)[3] == "1/2")
    any_player:Fire("deployitem", { prefab = "farm_plow_item" })
    Check("unfiltered deploy completes at the target", State(any_player) == "won")
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
    Check("filtered sleep row uses its bed's icon", Row(player, 1)[2] == "tent")

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
    Check("unfiltered sleep row defaults to the tent icon", Row(any_player, 1)[2] == "tent")
    any_player:Fire("guidedmissions_slept", { bed = { prefab = "bedroll_straw" } })
    Check("unfiltered sleep counts a bedroll", Row(any_player, 1)[3] == "1/2")
    any_player:Fire("guidedmissions_slept", { bed = { prefab = "siestahut" } })
    Check("unfiltered sleep completes at the target", State(any_player) == "won")

    -- `icon` overrides the bed art for a row that wants a specific picture.
    local icon_manager, icon_player = Spawn()
    Activate(icon_manager, icon_player, {
        id = "fixture_sleep_icon",
        title = "Any Bed",
        subtext = "Any port in a storm.",
        objectives = {
            { type = "sleep", count = 1, icon = "bedroll_straw", label = "Sleep in a bed" },
        },
    })
    Check("sleep icon override wins", Row(icon_player, 1)[2] == "bedroll_straw")
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

    -- Hunger is a valid reach_stat stat and uses the HUD hunger badge.
    local hunger_manager, hunger_player = Spawn(function(target)
        target.components.hunger = { current = 30, max = 100 }
    end)
    Activate(hunger_manager, hunger_player, {
        id = "fixture_reach_hunger",
        title = "Fed",
        subtext = "Eat.",
        objectives = {
            { type = "reach_stat", stat = "hunger", threshold = ">=50",
              label = "Get hunger back to 50%" },
        },
    })
    Check("reach_stat hunger icon is the hunger badge",
        Row(hunger_player, 1)[2] == "hunger")
    Check("reach_stat hunger counter", Row(hunger_player, 1)[3] == "30/50%")
    hunger_player.components.hunger.current = 60
    Advance(1)
    Check("reach_stat hunger completes", State(hunger_player) == "won")

    -- Temperature uses raw degrees in the counter.
    local temp_manager, temp_player = Spawn(function(target)
        target.components.temperature = { current = 80 }
    end)
    Activate(temp_manager, temp_player, {
        id = "fixture_reach_temperature",
        title = "Cool Off",
        subtext = "Hot.",
        objectives = {
            { type = "reach_stat", stat = "temperature", threshold = "<=50",
              label = "Cool down to 50°" },
        },
    })
    Check("reach_stat temperature counter uses degrees",
        Row(temp_player, 1)[3] == "80/50°")
    temp_player.components.temperature.current = 40
    Advance(1)
    Check("reach_stat temperature completes", State(temp_player) == "won")
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

    -- `exclude` drops prefabs vanilla files under VEGGIE that are not
    -- vegetables (butterfly wings are FOODTYPE.VEGGIE in
    -- prefabs/butterflywings.lua:39); `exclude_tags` drops Crock Pot dishes,
    -- which are VEGGIE by main ingredient but carry `preparedfood`.
    local veg_manager, veg_player = Spawn()
    Activate(veg_manager, veg_player, {
        id = "fixture_veggies",
        title = "Garden",
        subtext = "Things that grow.",
        objectives = {
            { type = "collect_food", foodtype = "VEGGIE", count = 2,
              exclude = { "butterflywings" },
              exclude_tags = { "preparedfood" },
              label = "Collect veggies" },
        },
    })
    CarryFood(veg_player, "butterflywings", 5, "VEGGIE", nil)
    InventoryChanged(veg_player)
    Check("excluded prefab does not count", Row(veg_player, 1)[3] == "0/2")
    CarryFood(veg_player, "trailmix", 5, "VEGGIE", nil, { preparedfood = true })
    InventoryChanged(veg_player)
    Check("excluded tag does not count", Row(veg_player, 1)[3] == "0/2")
    CarryFood(veg_player, "carrot", 2, "VEGGIE", nil)
    InventoryChanged(veg_player)
    Check("non-excluded veggie counts", State(veg_player) == "won")

    -- `prefabs` is the positive counterpart: only the listed ids count, even
    -- with no `foodtype` filter. This is how the veggies mission avoids
    -- vanilla's over-broad VEGGIE class.
    local list_manager, list_player = Spawn()
    Activate(list_manager, list_player, {
        id = "fixture_veggie_list",
        title = "Garden List",
        subtext = "Only these.",
        objectives = {
            { type = "collect_food", count = 2,
              prefabs = { "carrot", "berries" },
              label = "Collect veggies" },
        },
    })
    CarryFood(list_player, "butterflywings", 5, "VEGGIE", nil)
    InventoryChanged(list_player)
    Check("prefab outside the allow-list does not count",
        Row(list_player, 1)[3] == "0/2")
    CarryFood(list_player, "carrot", 1, "VEGGIE", nil)
    InventoryChanged(list_player)
    Check("listed prefab counts", Row(list_player, 1)[3] == "1/2")
    CarryFood(list_player, "berries", 1, "VEGGIE", "BERRY")
    InventoryChanged(list_player)
    Check("allow-list completes at target", State(list_player) == "won")
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

    -- `prefabs` accepts any of several held items, so one row covers the
    -- normal and juicy berry bushes (dug_berrybush, dug_berrybush2,
    -- dug_berrybush_juicy; prefabs/plantables.lua:118-137).
    local multi_manager, multi_player = Spawn()
    Activate(multi_manager, multi_player, {
        id = "fixture_plant_multi",
        title = "Berry Options",
        subtext = "Any bush will do.",
        objectives = {
            { type = "plant", prefabs = { "dug_berrybush", "dug_berrybush_juicy" },
                count = 1, label = "Replant a berry bush" },
        },
    })
    Check("multi-prefab plant icon is the first entry",
        Row(multi_player, 1)[2] == "dug_berrybush")
    multi_player:Fire("guidedmissions_planted", { item = "dug_sapling" })
    Check("a prefab outside the list is filtered out", State(multi_player) == "active")
    multi_player:Fire("guidedmissions_planted", { item = "dug_berrybush_juicy" })
    Check("any listed prefab completes the row", State(multi_player) == "won")
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
    Check("cook row defaults to the campfire icon", Row(player, 1)[2] == "campfire")

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

    -- A `self` row is the self-fertilize branch (Wormwood). It shows Manure by
    -- default, counts only the self event, and a normal plant row never reacts
    -- to the self event.
    local self_manager, self_player = Spawn(function(target)
        target.prefab = "wormwood"
    end)
    Activate(self_manager, self_player, {
        id = "fixture_fertilize_self",
        title = "Self Care",
        subtext = "Feed yourself.",
        objectives = {
            { type = "fertilize", self = true, count = 1, label = "Fertilize yourself" },
            { type = "fertilize", count = 1, label = "Fertilize a plant", optional = true },
        },
    })
    Check("self fertilize label is rendered",
        Row(self_player, 1)[1] == "Fertilize yourself")
    Check("self fertilize default icon is manure", Row(self_player, 1)[2] == "poop")
    self_player:Fire("guidedmissions_fertilized", { plant = { prefab = "grass" } })
    Check("self row ignores plant fertilization", Row(self_player, 1)[3] == "0/1")
    Check("plant row counts plant fertilization", Row(self_player, 2)[3] == "1/1")
    self_player:Fire("guidedmissions_self_fertilized", { fertilizer = "rot" })
    Check("self row counts self fertilization", Row(self_player, 1)[3] == "1/1")
    Check("self fertilization completes the mission", State(self_player) == "won")

    -- The plant branch never sees the self event either.
    local plant_manager, plant_player = Spawn()
    Activate(plant_manager, plant_player, {
        id = "fixture_fertilize_self_only",
        title = "Plant Only",
        subtext = "Just plants.",
        objectives = {
            { type = "fertilize", count = 1, label = "Fertilize a plant" },
        },
    })
    plant_player:Fire("guidedmissions_self_fertilized", { fertilizer = "manure" })
    Check("plant row ignores self fertilization", Row(plant_player, 1)[3] == "0/1")
    Check("a plant-only mission stays active", State(plant_player) == "active")
end

type_fixtures.equip = function()
    -- `tags` drives the entity's HasTag; `has_armor` adds the armor component.
    local function EquipItem(prefab, tags, has_armor)
        local item = { prefab = prefab, components = {} }
        if has_armor then
            item.components.armor = {}
        end
        function item:HasTag(tag)
            return tags ~= nil and tags[tag] == true
        end
        return item
    end

    -- Prefab filter, and live semantics: a second required row keeps the
    -- mission active so the row can be seen going on and off.
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_equip",
        title = "Armed",
        subtext = "Hold something useful.",
        objectives = {
            { type = "equip", prefab = "spear", label = "Equip a spear" },
            { type = "collect", prefab = "flint", count = 99, label = "Hold flint" },
        },
    })
    Check("equip label is rendered", Row(player, 1)[1] == "Equip a spear")
    Check("equip icon is the prefab", Row(player, 1)[2] == "spear")
    Check("equip starts unchecked", Row(player, 1)[3] == "0/1")

    player.components.inventory.equipslots.hands = EquipItem("axe", { weapon = true, tool = true })
    player:Fire("equip", {})
    Check("a different prefab does not check the row", Row(player, 1)[3] == "0/1")

    player.components.inventory.equipslots.hands = EquipItem("spear", { weapon = true })
    player:Fire("equip", {})
    Check("equipping the prefab checks the row", Row(player, 1)[3] == "1/1")
    Check("the other required row still gates completion", State(player) == "active")

    player.components.inventory.equipslots.hands = nil
    player:Fire("unequip", {})
    Check("unequipping unchecks the live row", Row(player, 1)[3] == "0/1")

    -- A category is a trait: the axe (weapon and tool) satisfies either.
    local weapon_manager, weapon_player = Spawn()
    Activate(weapon_manager, weapon_player, {
        id = "fixture_equip_weapon",
        title = "Any Weapon",
        subtext = "Something sharp.",
        objectives = {
            { type = "equip", category = "weapon", label = "Equip a weapon" },
        },
    })
    Check("weapon category default icon", Row(weapon_player, 1)[2] == "spear")
    weapon_player.components.inventory.equipslots.hands = EquipItem("log")
    weapon_player:Fire("equip", {})
    Check("a non-weapon does not satisfy the weapon category",
        State(weapon_player) == "active")
    weapon_player.components.inventory.equipslots.hands = EquipItem("axe", { weapon = true, tool = true })
    weapon_player:Fire("equip", {})
    Check("an axe satisfies the weapon category", State(weapon_player) == "won")

    local tool_manager, tool_player = Spawn()
    Activate(tool_manager, tool_player, {
        id = "fixture_equip_tool",
        title = "Any Tool",
        subtext = "Something useful.",
        objectives = {
            { type = "equip", category = "tool", label = "Equip a tool" },
        },
    })
    Check("tool category default icon", Row(tool_player, 1)[2] == "axe")
    tool_player.components.inventory.equipslots.hands = EquipItem("spear", { weapon = true })
    tool_player:Fire("equip", {})
    Check("a weapon alone is not a tool", State(tool_player) == "active")
    tool_player.components.inventory.equipslots.hands = EquipItem("pickaxe", { weapon = true, tool = true })
    tool_player:Fire("equip", {})
    Check("a pickaxe satisfies the tool category", State(tool_player) == "won")

    local armor_manager, armor_player = Spawn()
    Activate(armor_manager, armor_player, {
        id = "fixture_equip_armor",
        title = "Armor Up",
        subtext = "Take a hit.",
        objectives = {
            { type = "equip", category = "armor", label = "Equip armor" },
        },
    })
    Check("armor category default icon", Row(armor_player, 1)[2] == "armorwood")
    armor_player.components.inventory.equipslots.body = EquipItem("backpack")
    armor_player:Fire("equip", {})
    Check("a backpack is not armor", State(armor_player) == "active")
    armor_player.components.inventory.equipslots.body = EquipItem("armorwood", nil, true)
    armor_player:Fire("equip", {})
    Check("a log suit satisfies the armor category", State(armor_player) == "won")

    -- Category and slot combine.
    local slot_manager, slot_player = Spawn()
    Activate(slot_manager, slot_player, {
        id = "fixture_equip_slot",
        title = "Helmet",
        subtext = "Protect your head.",
        objectives = {
            { type = "equip", category = "armor", slot = "head",
              label = "Wear a helmet" },
        },
    })
    slot_player.components.inventory.equipslots.body = EquipItem("armorwood", nil, true)
    slot_player:Fire("equip", {})
    Check("body armor does not satisfy the head slot", State(slot_player) == "active")
    slot_player.components.inventory.equipslots.head = EquipItem("footballhat", nil, true)
    slot_player:Fire("equip", {})
    Check("head armor satisfies category and slot", State(slot_player) == "won")

    -- No filter: any equipped item, with no default icon.
    local any_manager, any_player = Spawn()
    Activate(any_manager, any_player, {
        id = "fixture_equip_any",
        title = "Anything",
        subtext = "Put it on.",
        objectives = {
            { type = "equip", label = "Equip an item" },
        },
    })
    Check("unfiltered equip row is text-only", Row(any_player, 1)[2] == "")
    any_player.components.inventory.equipslots.body = EquipItem("backpack")
    any_player:Fire("equip", {})
    Check("any equipped item satisfies an unfiltered row", State(any_player) == "won")

    -- Already equipped when the mission starts counts immediately.
    local start_manager, start_player = Spawn(function(target)
        target.components.inventory.equipslots.hands = EquipItem("spear", { weapon = true })
    end)
    Activate(start_manager, start_player, {
        id = "fixture_equip_initial",
        title = "Already Armed",
        subtext = "Good.",
        objectives = {
            { type = "equip", prefab = "spear", label = "Equip a spear" },
            { type = "collect", prefab = "flint", count = 99, label = "Hold flint" },
        },
    })
    Check("equipment worn at mission start counts", Row(start_player, 1)[3] == "1/1")
end

type_fixtures.haunt = function()
    -- A haunt is credited by the `haunt` event ACTIONS.HAUNT.fn pushes on the
    -- doer, matched by prefab or tag. It is a tracked row, so a required one
    -- can gate a mission.
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_haunt",
        title = "Touch the Stone",
        subtext = "Haunt it.",
        objectives = {
            { type = "haunt", prefab = "resurrectionstone",
              label = "Haunt a Touch Stone" },
        },
    })
    Check("haunt starts at zero", Row(player, 1)[3] == "0/1")
    Check("haunt icon follows the prefab", Row(player, 1)[2] == "resurrectionstone")
    player:Fire("haunt", { target = { prefab = "log" } })
    Check("haunting another prefab does not count", Row(player, 1)[3] == "0/1")
    player:Fire("haunt", { target = { prefab = "resurrectionstone" } })
    Check("haunting the named prefab counts", Row(player, 1)[3] == "1/1")
    Check("a required haunt row completes the mission", State(player) == "won")

    -- A tag filter matches related prefabs (the Florid Postern and its
    -- Celestial Portal upgrade), and a tag-only row names its icon.
    local tag_manager, tag_player = Spawn()
    Activate(tag_manager, tag_player, {
        id = "fixture_haunt_tag",
        title = "Haunt the Postern",
        subtext = "Any spawn portal.",
        objectives = {
            { type = "collect", prefab = "flint", count = 1, label = "Collect flint" },
            { type = "haunt", tag = "multiplayer_portal", icon = "multiplayer_portal",
              label = "Haunt a postern", optional = true },
        },
    })
    local moonrock_portal = { prefab = "multiplayer_portal_moonrock" }
    function moonrock_portal:HasTag(tag) return tag == "multiplayer_portal" end
    tag_player:Fire("haunt", { target = moonrock_portal })
    Check("a tag-filtered haunt counts a related entity", Row(tag_player, 2)[3] == "1/1")
    Check("a tag haunt row renders its named icon",
        Row(tag_player, 2)[2] == "multiplayer_portal")
    Check("an optional haunt row does not finish the mission", State(tag_player) == "active")
    Carry(tag_player, "flint", 1)
    InventoryChanged(tag_player)
    Check("the required row still completes the mission", State(tag_player) == "won")
end

type_fixtures.tip = function()
    -- A tip is informational: it renders after the required rows in the
    -- optional group, has no icon, no counter, and never completes. The blank
    -- counter is deliberate: the HUD treats a nil region size as zero width and
    -- pulls the label up to the right edge. It is optional whether or not the
    -- flag is set.
    local fixture_manager, player = Spawn()
    Activate(fixture_manager, player, {
        id = "fixture_tip",
        title = "Under the Boughs",
        subtext = "Trees keep the rain off.",
        objectives = {
            { type = "collect", prefab = "flint", count = 1, label = "Collect flint" },
            { type = "tip", label = "Stand under a tree" },
        },
    })
    Check("tip renders after the required rows", Row(player, 2)[1] == "Stand under a tree")
    Check("tip row is always optional", Row(player, 2)[5] == "1")
    Check("tip row renders no counter", Row(player, 2)[3] == "")
    Check("tip row has no icon by default", Row(player, 2)[2] == "")
    Check("tip row is never checked", Row(player, 2)[4] == "0")

    -- Unrelated events must not move it, and it never satisfies the mission.
    player:Fire("builditem", Build("torch"))
    player:Fire("killed", { victim = { prefab = "treeguard" } })
    Check("tip ignores objective events", Row(player, 2)[4] == "0")
    Check("tip alone does not complete the mission", State(player) == "active")

    Carry(player, "flint", 1)
    InventoryChanged(player)
    Check("required row completes while the tip stays unchecked",
        State(player) == "won" and Row(player, 2)[4] == "0")
    Check("won card still flags the tip as optional", Row(player, 2)[5] == "1")

    -- `icon` is the only other field a tip reads.
    local icon_manager, icon_player = Spawn()
    Activate(icon_manager, icon_player, {
        id = "fixture_tip_icon",
        title = "Under the Boughs",
        subtext = "Trees keep the rain off.",
        objectives = {
            { type = "collect", prefab = "flint", count = 1, label = "Collect flint" },
            { type = "tip", icon = "log", label = "Stand under a tree" },
        },
    })
    Check("tip icon override is rendered", Row(icon_player, 2)[2] == "log")
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

-- ---- character overrides ------------------------------------------------
--
-- `overrides` swaps one row's goal for a specific character (see
-- docs/objectives.md, "Character overrides"). Rows keep their position and the
-- slot's `optional` flag, and a character without an override sees the base row.

local override_mission = {
    id = "harness_override",
    title = "Override",
    subtext = "For some characters.",
    objectives = {
        { type = "eat", prefab = "butterflywings", count = 1, label = "Eat a butterfly wing",
          overrides = {
              wathgrithr = { type = "craft", prefab = "healingsalve", count = 1,
                             label = "Craft a Healing Salve" },
          } },
        { type = "sleep", count = 1, label = "Sleep in a tent", optional = true,
          overrides = {
              -- `false` hides the row for that character entirely.
              wickerbottom = false,
              wormwood = { type = "tip", label = "Food does not heal you" },
          } },
    },
}

-- A character without an override sees the base rows unchanged.
local base_manager, base_player = Spawn()
Activate(base_manager, base_player, override_mission)
Check("base character keeps the base label", Row(base_player, 1)[1] == "Eat a butterfly wing")
Check("base character keeps the base goal", Row(base_player, 1)[2] == "butterflywings")
Check("base character keeps the sleep row", Row(base_player, 2)[1] == "Sleep in a tent")

-- Wigfrid's required row resolves to the salve; later rows stay in place.
local wig_manager, wig_player = Spawn(function(target)
    target.prefab = "wathgrithr"
end)
Activate(wig_manager, wig_player, override_mission)
Check("Wigfrid sees the override label", Row(wig_player, 1)[1] == "Craft a Healing Salve")
Check("override icon follows the new goal", Row(wig_player, 1)[2] == "healingsalve")
Check("rows after the override stay in place", Row(wig_player, 2)[1] == "Sleep in a tent")
Check("optional flag survives the override", Row(wig_player, 2)[5] == "1")
wig_player:Fire("oneat", { food = { prefab = "butterflywings" } })
Check("the base goal no longer counts", Row(wig_player, 1)[3] == "0/1")
wig_player:Fire("builditem", Build("healingsalve"))
Check("the override goal completes the mission", State(wig_player) == "won")

-- Wickerbottom cannot sleep: each row resolved to `false` is dropped, so the
-- card shows one row fewer rather than an unreachable goal.
local wick_manager, wick_player = Spawn(function(target)
    target.prefab = "wickerbottom"
end)
Activate(wick_manager, wick_player, override_mission)
Check("Wickerbottom's sleep row is hidden", Row(wick_player, 2)[1] == nil)
Check("the resolved list omits the hidden row", #wick_manager.objectives == 1)
Check("the remaining row still renders",
    Row(wick_player, 1)[1] == "Eat a butterfly wing")

-- Wormwood's replacement is a tip: a row that never completes, but is shown.
local worm_manager, worm_player = Spawn(function(target)
    target.prefab = "wormwood"
end)
Activate(worm_manager, worm_player, override_mission)
Check("Wormwood sees the tip", Row(worm_player, 2)[1] == "Food does not heal you")
Check("the tip starts unchecked", Row(worm_player, 2)[4] == "0")
worm_player:Fire("guidedmissions_slept", { bed = { prefab = "tent" } })
Check("the tip never completes", Row(worm_player, 2)[4] == "0")

-- The real restore_health mission gives every character who cannot eat
-- butterfly wings (or gains nothing from food) a route their diet allows.
do
    local restore_health
    for _, mission in ipairs(RealMissions) do
        if mission.id == "restore_health" then
            restore_health = mission
        end
    end
    Check("the real restore_health mission exists", restore_health ~= nil)
    if restore_health ~= nil then
        local expected = {
            wathgrithr = "Eat a Spider Gland",
            warly = "Eat Trail Mix",
            wormwood = "Fertilize yourself",
        }
        for character, label in pairs(expected) do
            local manager, player = Spawn(function(target)
                target.prefab = character
            end)
            Activate(manager, player, restore_health)
            Check(character .. " sees " .. label, Row(player, 1)[1] == label)
        end
        local manager, player = Spawn()
        Activate(manager, player, restore_health)
        Check("other characters keep the butterfly wing",
            Row(player, 1)[1] == "Eat a butterfly wing")
    end
end

-- ---- real mission render smoke ------------------------------------------
--
-- Activate every mission in the real chain and check it renders one well-formed
-- row per objective. This catches label/icon/counter crashes in mission data
-- without pinning any content: titles, counts, order and wording may change
-- freely.

-- Every row must carry a label and a done flag; every row except a `tip` must
-- also carry a counter. A tip has no progress, so its counter is deliberately
-- blank and the HUD guards the nil measurement (See BuildRows in the tracker).
-- Rows are emitted required-then-optional, and a tip is always optional, so
-- the expected row order is reproduced here to know which row is a tip.
local function WellFormedRows(objectives, rows)
    local is_tip = {}
    for pass = 1, 2 do
        for _, objective in ipairs(objectives or {}) do
            local optional = objective.type == "tip" or objective.optional == true
            if optional == (pass == 2) then
                is_tip[#is_tip + 1] = objective.type == "tip"
            end
        end
    end
    for i, fields in ipairs(rows) do
        if fields[1] == nil or fields[1] == ""
            or fields[4] == nil then
            return false
        end
        if (fields[3] == nil or fields[3] == "") and not is_tip[i] then
            return false
        end
    end
    return true
end

for i, mission in ipairs(RealMissions) do
    local smoke_manager, player = Spawn()
    Activate(smoke_manager, player, mission)

    local label = string.format("real mission %d (%s) renders", i, tostring(mission.id))
    local rows = Rows(Read(player)["guidedmissions.rows"])
    Check(label .. " one row per objective", #rows == #(mission.objectives or {}))
    Check(label .. " every row has a label, counter and done flag",
        WellFormedRows(mission.objectives, rows))
end

-- ---- real emergency render smoke ----------------------------------------
--
-- Same contract as the mission smoke, using the real emergency entries.
-- Portal resurrection is on here so the death card's gated postern row renders
-- and the expected row count matches the entry's objective list.

TheWorld.components = { worldsettings = { GetSetting = function(_, name)
    return name == "portal_rez" and true or nil
end } }

for i, entry in ipairs(RealEmergencies.entries) do
    local smoke_manager, player = Spawn()
    Check("real emergency " .. i .. " activates",
        smoke_manager:ActivateEmergency(entry) == true)

    local label = string.format("real emergency %d (%s) renders", i, tostring(entry.id))
    Check(label .. " state", State(player) == "emergency")
    Check(label .. " title", Read(player)["guidedmissions.title"] == entry.title)

    local rows = Rows(Read(player)["guidedmissions.rows"])
    Check(label .. " one row per objective", #rows == #(entry.objectives or {}))

    -- Same contract as the mission smoke, blank counters allowed on tips only.
    Check(label .. " every row has a label, counter and done flag",
        WellFormedRows(entry.objectives, rows))
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
