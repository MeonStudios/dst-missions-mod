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

-- Rows are `label|prefab|counter|done` joined by `;`, so the separators must
-- never appear inside the free-form label.
local function SanitiseLabel(text)
    return (tostring(text or ""):gsub("[|;]", " "))
end

-- Pack the mission's objectives into the client's row format. `force_done`
-- renders every row as complete for the 3-second completion hold.
local function FormatRows(mission, progress, force_done)
    local rows = {}
    for i, objective in ipairs(mission.objectives or {}) do
        local value = progress[i] or 0
        local done = (force_done or Objectives.IsComplete(objective, value)) and 1 or 0
        rows[#rows + 1] = table.concat({
            SanitiseLabel(Objectives.GetLabel(objective)),
            Objectives.GetIconPrefab(objective) or "",
            Objectives.GetCounter(objective, value),
            tostring(done),
        }, "|")
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

    -- No `itemget` listener: collect progress is read from the inventory by
    -- the poller (see Objectives.ReconcileProgress for why events cannot be
    -- trusted). Crafting/building and kills are event-driven.
    -- Inventory-item recipes (torch) fire `builditem`; structures (firepit,
    -- researchlab) fire `buildstructure` instead. See objectives.lua.
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
    -- `guidedmissions_cookedfood` and `guidedmissions_stewedfood` are pushed by
    -- modmain's `cooker`/`stewer` component post-inits, because vanilla fire and
    -- crockpot cooking emit no player event. `unlockrecipe` is vanilla:
    -- Builder:UnlockRecipe pushes it when a recipe is prototyped or learned.
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
    inst:ListenForEvent("unlockrecipe", function(_, data)
        self:OnUnlockRecipe(data)
    end)

    -- Survival objectives depend on world day, and this also refreshes the
    -- "day X" display in the tracker.
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

-- Switch to an arbitrary mission (1-based), discarding progress on the current
-- one. `#Missions + 1` is the terminal "all missions complete" state. Returns
-- false for an out-of-range index and changes nothing in that case. Used by the
-- /resetmissions and /setmission admin commands. Tracker state only: no game
-- state is touched, and the inventory is left alone (it counts as starting
-- inventory for collect objectives, exactly as a fresh mission would).
function GuidedMissionManager:JumpTo(index)
    index = tonumber(index)
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
        mission.title or "Untitled"
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

function GuidedMissionManager:OnPoll()
    if self.completed or self.current_mission == nil then
        return
    end

    -- collect/collect_food objectives are inventory-derived: reread them every poll.
    -- This is the only place their progress changes (see
    -- Objectives.ReconcileProgress).
    for i, objective in ipairs(self.current_mission.objectives or {}) do
        self.progress[i] = Objectives.ReconcileProgress(self.inst, objective, self.progress[i])
    end

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
        if not Objectives.IsComplete(objective, self.progress[i] or 0) then
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
        title = mission.title or "Mission",
        subtext = mission.subtext or "",
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
        mission.title or "Untitled"
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
        title = mission.title or "Mission",
        subtext = mission.subtext or "",
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

    if self.hold_task ~= nil then
        self.hold_task:Cancel()
        self.hold_task = nil
    end
end

return GuidedMissionManager
