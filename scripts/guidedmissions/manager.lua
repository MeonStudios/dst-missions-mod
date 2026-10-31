-- See netvars.lua: require()d modules cannot see modmain's `GLOBAL` binding.
local GLOBAL = _G

local Missions = require("guidedmissions/missions")
local Objectives = require("guidedmissions/objectives")
local Netvars = require("guidedmissions/netvars")
local Settings = require("guidedmissions/settings")

local function FindMissionIndexById(id)
    for i, mission in ipairs(Missions) do
        if mission.id == id then
            return i
        end
    end
    return nil
end

local GuidedMissionManager = Class(function(self, inst)
    self.inst = inst
    self.mission_index = 0
    self.current_mission = nil
    self.progress = {}
    self.completed = false
    self.started = false
    self.loaded = false

    inst:ListenForEvent("itemget", function(_, data)
        self:OnObjectiveEvent("itemget", data)
    end)
    inst:ListenForEvent("builditem", function(_, data)
        self:OnObjectiveEvent("builditem", data)
    end)
    inst:ListenForEvent("killed", function(_, data)
        self:OnObjectiveEvent("killed", data)
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

function GuidedMissionManager:Begin()
    if self.started then
        return
    end
    self.started = true

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
    self:Announce(string.format(
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
        local increment = Objectives.GetEventIncrement(objective, event, data)
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

    -- This mod is informational only: completing a mission never changes game
    -- state. Clear the active mission so completion cannot be re-entered.
    self.current_mission = nil
    self.progress = {}

    self:Announce(string.format(
        "%s completed: %s",
        self.inst:GetDisplayName(),
        mission.title or "Untitled"
    ))

    self:SetMission(self.mission_index + 1)
end

function GuidedMissionManager:Sync()
    if self.completed then
        Netvars.Write(self.inst, {
            title = "Guided Missions",
            objectives = "All missions complete!",
            footer = "",
        })
        return
    end

    local mission = self.current_mission
    if mission == nil then
        return
    end

    local lines = {}
    for i, objective in ipairs(mission.objectives or {}) do
        lines[#lines + 1] = Objectives.GetStatusLine(objective, self.progress[i] or 0)
    end

    Netvars.Write(self.inst, {
        title = mission.title or "Mission",
        objectives = table.concat(lines, "\n"),
        footer = string.format("Mission %d of %d", self.mission_index, #Missions),
    })
end

function GuidedMissionManager:Announce(message)
    print("[Guided Missions] " .. tostring(message))
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
end

return GuidedMissionManager
