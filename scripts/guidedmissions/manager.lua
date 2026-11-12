-- See netvars.lua: require()d modules cannot see modmain's `GLOBAL` binding.
local GLOBAL = _G

local Missions = require("guidedmissions/missions")
local Objectives = require("guidedmissions/objectives")
local Netvars = require("guidedmissions/netvars")
local Settings = require("guidedmissions/settings")

local HOLD_SECONDS = 3

local function FindMissionIndexById(id)
    for i, mission in ipairs(Missions) do
        if mission.id == id then
            return i
        end
    end
    return nil
end

local function HasSurviveObjective(mission)
    for _, objective in ipairs(mission.objectives or {}) do
        if objective.type == "survive" then
            return true
        end
    end
    return false
end

-- Rows are `label|prefab|counter|done|optional` joined by `;`, so the
-- separators must never appear inside the free-form label.
local function SanitiseLabel(text)
    return (tostring(text):gsub("[|;]", " "))
end

-- Pack the mission's objectives into the client's row format. Required rows
-- are emitted before optional ones regardless of authoring order, so the HUD
-- can draw one "Optional" heading above the second group. `force_done` renders
-- the required rows as complete for the 3-second completion hold; optional
-- rows keep their real state so an unfinished one never shows a check.
local function FormatRows(mission, progress, force_done)
    local rows = {}
    for pass = 1, 2 do
        local want_optional = pass == 2
        for i, objective in ipairs(mission.objectives or {}) do
            local optional = Objectives.IsOptional(objective)
            if optional == want_optional then
                local value = progress[i] or 0
                local done = ((force_done and not optional)
                    or Objectives.IsComplete(objective, value)) and 1 or 0
                rows[#rows + 1] = table.concat({
                    SanitiseLabel(Objectives.GetLabel(objective)),
                    Objectives.GetIconPrefab(objective) or "",
                    Objectives.GetCounter(objective, value),
                    tostring(done),
                    optional and "1" or "0",
                }, "|")
            end
        end
    end
    return table.concat(rows, ";")
end

local GuidedMissionManager = Class(function(self, inst)
    self.inst = inst
    self.mission_index = 0
    self.current_mission = nil
    self.progress = {}
    self.completed = false
    self.started = false
    self.loaded = false
    -- Recipe ids the player already knew (or has been credited for). Vanilla
    -- pushes `unlockrecipe` again for every structure placement (widgetutil
    -- calls UnlockRecipe unconditionally), so prototype objectives count only
    -- the first sighting. Seeded from builder.recipes after load (Begin).
    self.known_recipes = {}

    -- Pending deferred inventory reread (see OnInventoryChanged).
    self.inventory_task = nil
    -- Last world day the survive counter was synced for (see OnPoll).
    self.last_poll_day = nil

    -- Inventory-derived objectives (collect, collect_food) are reread from the
    -- inventory, never accumulated from events -- but an event is still what
    -- triggers the reread. These four cover every way an item joins the
    -- inventory; see Objectives.ReconcileProgress and docs/dst-api.md.
    -- Inventory-item recipes (torch) fire `builditem`; structures (firepit,
    -- researchlab) fire `buildstructure` instead. See objectives.lua.
    local function oninventory(_, _)
        self:OnInventoryChanged()
    end
    inst:ListenForEvent("itemget", oninventory)
    inst:ListenForEvent("gotnewitem", oninventory)
    inst:ListenForEvent("newactiveitem", oninventory)
    inst:ListenForEvent("setoverflow", oninventory)
    inst:ListenForEvent("builditem", function(_, data)
        self:OnObjectiveEvent("builditem", data)
    end)
    inst:ListenForEvent("buildstructure", function(_, data)
        self:OnObjectiveEvent("buildstructure", data)
    end)
    inst:ListenForEvent("killed", function(_, data)
        self:OnObjectiveEvent("killed", data)
    end)
    -- `working` fires on the worker for every workable swing (chop, mine, dig,
    -- hammer); the chop/mine objectives inspect `data.target` to tell a felled
    -- tree or a finished boulder from the rest. `oneat` fires on the eater with
    -- the food entity, `picksomething` on the picker with the plant,
    -- `healthdelta`/`sanitydelta` on any stat change. All are pushed server-side.
    -- `guidedmissions_cookedfood`, `guidedmissions_stewedfood` and
    -- `guidedmissions_plantedseed` are pushed by modmain's component post-inits,
    -- because vanilla fire cooking, crockpot cooking and seed planting emit no
    -- player event. `unlockrecipe` is vanilla: Builder:UnlockRecipe pushes it
    -- when a recipe is prototyped or learned.
    inst:ListenForEvent("working", function(_, data)
        self:OnObjectiveEvent("working", data)
    end)
    inst:ListenForEvent("oneat", function(_, data)
        self:OnObjectiveEvent("oneat", data)
    end)
    inst:ListenForEvent("picksomething", function(_, data)
        self:OnObjectiveEvent("picksomething", data)
    end)
    inst:ListenForEvent("healthdelta", function(_, data)
        self:OnObjectiveEvent("healthdelta", data)
    end)
    inst:ListenForEvent("sanitydelta", function(_, data)
        self:OnObjectiveEvent("sanitydelta", data)
    end)
    inst:ListenForEvent("guidedmissions_cookedfood", function(_, data)
        self:OnObjectiveEvent("guidedmissions_cookedfood", data)
    end)
    inst:ListenForEvent("guidedmissions_stewedfood", function(_, data)
        self:OnObjectiveEvent("guidedmissions_stewedfood", data)
    end)
    inst:ListenForEvent("guidedmissions_plantedseed", function(_, data)
        self:OnObjectiveEvent("guidedmissions_plantedseed", data)
    end)
    -- Pushed by modmain's `trap` post-init when the player checks a sprung trap
    -- that holds a catch (`data.loot` is the trap's loot prefab list).
    inst:ListenForEvent("guidedmissions_trapchecked", function(_, data)
        self:OnObjectiveEvent("guidedmissions_trapchecked", data)
    end)
    inst:ListenForEvent("unlockrecipe", function(_, data)
        self:OnUnlockRecipe(data)
    end)

    -- The only time-based objective left is `survive`, whose counter follows
    -- the world day. Every other type is event-driven, including the
    -- inventory-derived ones, so OnPoll no-ops unless a survive row exists.
    self.poll_task = inst:DoPeriodicTask(1, function()
        self:OnPoll()
    end)

    -- Give OnLoad a chance to run before starting the chain.
    self.begin_task = inst:DoTaskInTime(1, function()
        self.begin_task = nil
        self:Begin()
    end)
end)

-- Seed from the builder's learned list. This runs after OnLoad (Begin is
-- delayed a second), so loaded saves and character starting recipes are marked
-- as already known rather than counted when they are re-triggered.
function GuidedMissionManager:SnapshotKnownRecipes()
    local builder = self.inst.components ~= nil and self.inst.components.builder or nil
    local recipes = builder ~= nil and builder.recipes or nil
    if recipes ~= nil then
        for i = 1, #recipes do
            self.known_recipes[recipes[i]] = true
        end
    end
end

-- Vanilla re-pushes `unlockrecipe` for known recipes in some paths (notably
-- structure placement via widgets/widgetutil.lua), so credit only the first
-- sighting of each recipe. See docs/dst-api.md, "Recipe prototyping".
function GuidedMissionManager:OnUnlockRecipe(data)
    local recipe = data ~= nil and data.recipe or nil
    if recipe == nil or self.known_recipes[recipe] then
        return
    end
    self.known_recipes[recipe] = true
    self:OnObjectiveEvent("unlockrecipe", { recipe = recipe })
end

function GuidedMissionManager:Begin()
    if self.started then
        return
    end
    self.started = true
    self:SnapshotKnownRecipes()

    if self.completed then
        self:Sync()
        return
    end

    if self.loaded and self.mission_index >= 1 then
        self.current_mission = Missions[self.mission_index]
        if self.current_mission == nil then
            self.completed = true
            self.mission_index = #Missions + 1
        end
        self:Sync()
        return
    end

    self:SetMission(1)
end

-- Jump targets can be a 1-based mission number (2 or "2") or a stable mission
-- id ("green_thumb"). Ids are what save state keys on, so naming one is
-- clearer than counting positions in missions.lua. An unknown id resolves to
-- nil and is rejected like an out-of-range number.
local function ResolveMissionIndex(target)
    if type(target) == "number" then
        return target
    end
    if type(target) ~= "string" then
        return nil
    end

    local numeric = tonumber(target)
    if numeric ~= nil then
        return numeric
    end
    return FindMissionIndexById(target)
end

-- Switch to an arbitrary mission, discarding progress on the current one.
-- Accepts a 1-based index or a mission id (see ResolveMissionIndex).
-- `#Missions + 1` is the terminal "all missions complete" state, reachable by
-- number only. Returns false for an unknown target and changes nothing in that
-- case. Used by the c_resetmissions/c_setmission admin commands. Tracker state
-- only: no game state is touched, and the inventory is left alone (it counts
-- as starting inventory for collect objectives, exactly as a fresh mission
-- would).
function GuidedMissionManager:JumpTo(target)
    local index = ResolveMissionIndex(target)
    if index == nil or index < 1 or index > #Missions + 1 then
        return false
    end

    -- A console jump can happen before Begin's snapshot; keep prototype
    -- objectives from counting recipes the player already knew.
    self:SnapshotKnownRecipes()

    if self.begin_task ~= nil then
        self.begin_task:Cancel()
        self.begin_task = nil
        self.started = true
    end

    if self.hold_task ~= nil then
        self.hold_task:Cancel()
        self.hold_task = nil
    end

    self.loaded = false
    self.mission_index = 0
    self:SetMission(index)
    return true
end

function GuidedMissionManager:Reset()
    self:JumpTo(1)
end

function GuidedMissionManager:SetMission(index)
    self.mission_index = index
    local mission = Missions[index]

    if mission == nil then
        self.current_mission = nil
        self.progress = {}
        self.completed = true
        self:Sync()
        self:Announce("All guided missions are complete!")
        return
    end

    self.completed = false
    self.current_mission = mission
    self.progress = {}
    self.last_poll_day = nil

    for i, objective in ipairs(mission.objectives or {}) do
        self.progress[i] = Objectives.InitialProgress(self.inst, objective)
    end

    self:Sync()
    -- Server log only: the HUD already shows the mission, and announcing every
    -- start would spam chat (especially with /setmission).
    self:Log(string.format(
        "%s - Mission %d: %s",
        self.inst:GetDisplayName(),
        index,
        mission.title
    ))

    -- A freshly activated mission can already be satisfied (for example, a
    -- survival objective whose day has passed).
    self:CheckCompletion()
end

function GuidedMissionManager:OnObjectiveEvent(event, data)
    if self.completed or self.current_mission == nil then
        return
    end

    local changed = false
    for i, objective in ipairs(self.current_mission.objectives or {}) do
        local increment = Objectives.GetEventIncrement(objective, event, data, self.inst)
        if increment > 0 then
            self.progress[i] = (self.progress[i] or 0) + increment
            changed = true
        end
    end

    if changed then
        self:CheckCompletion()
        if not self.completed and self.current_mission ~= nil then
            self:Sync()
        end
    end
end

-- Defer the reread by a tick: `gotnewitem` is pushed *before* the item is
-- placed or merged (components/inventory.lua:1100 vs the `stackable:Put` at
-- :1146), so reconciling inside the event handler would read a stale count.
-- Coalesce a burst of pickups into one reread.
function GuidedMissionManager:OnInventoryChanged()
    if self.completed or self.current_mission == nil or self.inventory_task ~= nil then
        return
    end

    self.inventory_task = self.inst:DoTaskInTime(0, function()
        self.inventory_task = nil
        self:ReconcileInventory()
    end)
end

-- Reread every inventory-derived objective and keep the peak. Events only
-- trigger this; the count always comes from `inventory:ForEachItem`, so a
-- spurious event cannot inflate progress (see Objectives.ReconcileProgress).
function GuidedMissionManager:ReconcileInventory()
    if self.completed or self.current_mission == nil then
        return
    end

    local changed = false
    for i, objective in ipairs(self.current_mission.objectives or {}) do
        local value = Objectives.ReconcileProgress(self.inst, objective, self.progress[i])
        if value ~= self.progress[i] then
            self.progress[i] = value
            changed = true
        end
    end

    if changed then
        self:CheckCompletion()
        if not self.completed and self.current_mission ~= nil then
            self:Sync()
        end
    end
end

-- Only `survive` still needs a periodic read. Syncing only when the day
-- changes keeps an idle mission down to one timer wake-up per second.
function GuidedMissionManager:OnPoll()
    if self.completed or self.current_mission == nil then
        return
    end
    if not HasSurviveObjective(self.current_mission) then
        return
    end

    local day = Objectives.GetCurrentDay()
    if day == self.last_poll_day then
        return
    end
    self.last_poll_day = day

    self:CheckCompletion()
    if not self.completed and self.current_mission ~= nil then
        self:Sync()
    end
end

function GuidedMissionManager:CheckCompletion()
    local mission = self.current_mission
    if mission == nil then
        return
    end

    for i, objective in ipairs(mission.objectives or {}) do
        -- Optional objectives are tracked but never gate completion.
        if not Objectives.IsOptional(objective)
            and not Objectives.IsComplete(objective, self.progress[i] or 0) then
            return
        end
    end

    self:CompleteCurrentMission()
end

function GuidedMissionManager:CompleteCurrentMission()
    local mission = self.current_mission
    if mission == nil then
        return
    end

    -- Show the completed card before clearing state. This mod is informational
    -- only: completing a mission never changes game state.
    Netvars.Write(self.inst, {
        title = mission.title,
        subtext = mission.subtext or "",
        -- No hint on the completion card: every row is checked and the helper
        -- button would only clutter the 3-second hold.
        hint = "",
        rows = FormatRows(mission, self.progress, true),
        state = "won",
    })

    -- Clearing the mission makes objective events and the poller ignore
    -- progress for the duration of the hold.
    self.current_mission = nil
    self.progress = {}

    self:Announce(string.format(
        "%s completed: %s",
        self.inst:GetDisplayName(),
        mission.title
    ))

    if self.hold_task ~= nil then
        self.hold_task:Cancel()
        self.hold_task = nil
    end

    local next_index = self.mission_index + 1
    self.mission_index = next_index
    self.hold_task = self.inst:DoTaskInTime(HOLD_SECONDS, function()
        self.hold_task = nil
        self:SetMission(next_index)
    end)
end

function GuidedMissionManager:Sync()
    if self.completed then
        Netvars.Write(self.inst, {
            title = "All Missions Complete",
            subtext = "You survived. For now.",
            hint = "",
            rows = "",
            state = "done",
        })
        return
    end

    local mission = self.current_mission
    if mission == nil then
        return
    end

    Netvars.Write(self.inst, {
        title = mission.title,
        subtext = mission.subtext or "",
        -- Optional per-mission hint, shown by the tracker behind a hover on the
        -- "?" button. Absent (nil) is written as "" so the button hides.
        hint = mission.hint or "",
        rows = FormatRows(mission, self.progress, false),
        state = "active",
    })
end

-- Server-log line only.
function GuidedMissionManager:Log(message)
    print("[Guided Missions] " .. tostring(message))
end

-- Server log plus chat, for completions. Mission starts use Log instead.
function GuidedMissionManager:Announce(message)
    self:Log(message)
    if Settings.announce_missions and GLOBAL.TheNet ~= nil then
        GLOBAL.TheNet:Announce(message)
    end
end

function GuidedMissionManager:OnSave()
    return {
        mission_index = self.mission_index,
        mission_id = self.current_mission ~= nil and self.current_mission.id or nil,
        progress = self.progress,
        completed = self.completed,
    }
end

function GuidedMissionManager:OnLoad(data)
    if type(data) ~= "table" then
        return
    end

    self.mission_index = tonumber(data.mission_index) or 0
    self.progress = type(data.progress) == "table" and data.progress or {}
    self.completed = data.completed == true
    self.loaded = true

    -- Prefer the stable mission id so reordering missions.lua does not
    -- silently move an in-progress player to the wrong mission.
    if data.mission_id ~= nil then
        local index = FindMissionIndexById(data.mission_id)
        if index ~= nil then
            self.mission_index = index
        end
    end

    -- Normally OnLoad runs before Begin, but stay correct if it does not.
    if self.started then
        if self.completed then
            self.current_mission = nil
        else
            self.current_mission = Missions[self.mission_index]
            if self.current_mission == nil then
                self.completed = true
                self.mission_index = #Missions + 1
            end
        end
        self:Sync()
    end
end

function GuidedMissionManager:OnRemoveFromEntity()
    if self.begin_task ~= nil then
        self.begin_task:Cancel()
        self.begin_task = nil
    end

    if self.poll_task ~= nil then
        self.poll_task:Cancel()
        self.poll_task = nil
    end

    if self.inventory_task ~= nil then
        self.inventory_task:Cancel()
        self.inventory_task = nil
    end

    if self.hold_task ~= nil then
        self.hold_task:Cancel()
        self.hold_task = nil
    end
end

return GuidedMissionManager
