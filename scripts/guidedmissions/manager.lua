-- See netvars.lua: require()d modules cannot see modmain's `GLOBAL` binding.
local GLOBAL = _G

local Missions = require("guidedmissions/missions")
local Emergencies = require("guidedmissions/emergencies")
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

    -- Emergency overlay. While `emergency` is set it is the visible mission and
    -- the chain mission waits in `suspended_mission`/`suspended_progress`.
    -- `fired_emergencies` remembers triggered ids; whether it survives a load
    -- depends on Settings.emergency_frequency (see OnSave/OnLoad).
    self.emergency = nil
    self.suspended_mission = nil
    self.suspended_progress = nil
    self.fired_emergencies = {}
    -- Pending 3-second recovered-card hold (see ResolveEmergency).
    self.emergency_hold_task = nil

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
    -- `guidedmissions_planted` are pushed by modmain's component post-inits,
    -- because vanilla fire cooking, crockpot cooking and planting emit no
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
    -- Stat events drive emergency triggering/resolution immediately; the poll
    -- is the fallback for changes that push no event (loads, console sets).
    inst:ListenForEvent("healthdelta", function(_, data)
        self:OnObjectiveEvent("healthdelta", data)
        self:CheckEmergencies()
    end)
    inst:ListenForEvent("sanitydelta", function(_, data)
        self:OnObjectiveEvent("sanitydelta", data)
        self:CheckEmergencies()
    end)
    inst:ListenForEvent("guidedmissions_cookedfood", function(_, data)
        self:OnObjectiveEvent("guidedmissions_cookedfood", data)
    end)
    inst:ListenForEvent("guidedmissions_stewedfood", function(_, data)
        self:OnObjectiveEvent("guidedmissions_stewedfood", data)
    end)
    -- Pushed by modmain's `farmplantable`/`deployable` post-inits when the
    -- player plants a seed, a dug plant or another plantable (`data.item` is
    -- the held item's prefab id).
    inst:ListenForEvent("guidedmissions_planted", function(_, data)
        self:OnObjectiveEvent("guidedmissions_planted", data)
    end)
    -- Pushed by modmain's `sleepingbaguser` post-init when the player enters a
    -- tent/bedroll (`data.bed` is the bed entity).
    inst:ListenForEvent("guidedmissions_slept", function(_, data)
        self:OnObjectiveEvent("guidedmissions_slept", data)
    end)
    -- Pushed by modmain's `trap` post-init when the player checks a sprung trap
    -- that holds a catch (`data.loot` is the trap's loot prefab list).
    inst:ListenForEvent("guidedmissions_trapchecked", function(_, data)
        self:OnObjectiveEvent("guidedmissions_trapchecked", data)
    end)
    -- Pushed by modmain's `pickable` post-init when the player fertilizes a
    -- barren or withered bush/grass (`data.plant` is the fertilized entity).
    inst:ListenForEvent("guidedmissions_fertilized", function(_, data)
        self:OnObjectiveEvent("guidedmissions_fertilized", data)
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
        self:RefreshLiveObjectives()
        -- A player who loads in below an emergency threshold should see the
        -- pop-up immediately rather than wait for the next poll.
        self:CheckEmergencies()
        return
    end

    self:SetMission(1)
    self:RefreshLiveObjectives()
    self:CheckEmergencies()
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

    -- Drop any emergency overlay or recovered-card hold: the jump replaces the
    -- visible mission, including the one the emergency paused.
    self:ClearEmergency()

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
    -- A reset is also the admin's way to re-arm emergencies for another test.
    self.fired_emergencies = {}
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

    -- `reach_stat` rows are not accumulated from the event; they mirror the
    -- current stat, including when the event added no increment.
    self:RefreshLiveObjectives()
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

-- Keep `reach_stat` rows on the live stat. Called from stat events, at Begin,
-- and once per second; this is why the required goal row on an emergency card
-- always matches the value that resolves it.
function GuidedMissionManager:RefreshLiveObjectives()
    local mission = self.current_mission
    if mission == nil then
        return
    end

    local changed = false
    for i, objective in ipairs(mission.objectives or {}) do
        local value = Objectives.LiveProgress(self.inst, objective)
        if value ~= nil and value ~= self.progress[i] then
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

-- The poll is also the fallback emergency trigger, so it keeps running even
-- when the active mission has no survive row. The survive read still syncs only
-- when the world day changes, so an idle mission stays cheap.
function GuidedMissionManager:OnPoll()
    if self.completed then
        return
    end

    -- Refresh live stat rows first so a silent recovery updates the required
    -- goal row before CheckEmergencies writes the resolved card.
    self:RefreshLiveObjectives()
    self:CheckEmergencies()
    -- A resolved emergency is showing its recovered card for a moment; nothing
    -- else should touch the tracker until it restores the chain mission.
    if self.completed or self.current_mission == nil or self.emergency ~= nil then
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

-- ---------------------------------------------------------------- emergencies

-- "always" ignores the fired set entirely; the resolve condition is the only
-- guard. "session" and "server" remember triggered ids (the latter in the save).
function GuidedMissionManager:EmergencyAlreadyFired(id)
    return Settings.emergency_frequency ~= "always"
        and self.fired_emergencies[id] == true
end

function GuidedMissionManager:MarkEmergencyFired(id)
    if Settings.emergency_frequency ~= "always" then
        self.fired_emergencies[id] = true
    end
end

-- Called on stat events, at Begin, and once per second. It both starts an
-- emergency and resolves the active one.
function GuidedMissionManager:CheckEmergencies()
    if self.emergency ~= nil then
        if Emergencies.IsResolved(self.emergency, self.inst) then
            self:ResolveEmergency()
        end
        return
    end

    -- Nothing to replace: not started, chain finished, between missions (the
    -- 3-second won hold), or showing a recovered card.
    if not self.started or self.completed or self.current_mission == nil
        or self.hold_task ~= nil or self.emergency_hold_task ~= nil then
        return
    end

    -- Ghosts cannot act on their stats (a dead player's health reads 0).
    local health = self.inst.components ~= nil and self.inst.components.health or nil
    if health ~= nil and health.IsDead ~= nil and health:IsDead() then
        return
    end

    -- First matching entry wins; file order is the tie-breaker.
    for _, entry in ipairs(Emergencies.entries) do
        if not self:EmergencyAlreadyFired(entry.id)
            and Emergencies.IsTriggered(entry, self.inst) then
            self:ActivateEmergency(entry)
            return
        end
    end
end

function GuidedMissionManager:ActivateEmergency(entry)
    if entry == nil or self.emergency ~= nil or self.current_mission == nil then
        return false
    end

    -- Pause the chain: keep both the mission and its exact progress table.
    self.suspended_mission = self.current_mission
    self.suspended_progress = self.progress

    self.emergency = entry
    self:MarkEmergencyFired(entry.id)
    self.current_mission = entry
    self.progress = {}
    self.last_poll_day = nil

    for i, objective in ipairs(entry.objectives or {}) do
        self.progress[i] = Objectives.InitialProgress(self.inst, objective)
    end

    self:Sync()
    self:Log(string.format(
        "%s - Emergency: %s",
        self.inst:GetDisplayName(),
        entry.title
    ))
    return true
end

-- Show the recovered card, then restore the paused chain mission after the
-- same 3-second hold a normal completion uses. The chain index never moves.
function GuidedMissionManager:ResolveEmergency()
    local entry = self.emergency
    if entry == nil then
        return
    end

    Netvars.Write(self.inst, {
        title = entry.title,
        subtext = entry.resolved_subtext or entry.subtext or "",
        hint = "",
        rows = FormatRows(entry, self.progress, false),
        state = "won",
    })

    self.emergency = nil
    self.current_mission = nil
    self.progress = {}

    self:Log(string.format(
        "%s - Emergency resolved: %s",
        self.inst:GetDisplayName(),
        entry.title
    ))

    if self.emergency_hold_task ~= nil then
        self.emergency_hold_task:Cancel()
        self.emergency_hold_task = nil
    end

    self.emergency_hold_task = self.inst:DoTaskInTime(HOLD_SECONDS, function()
        self.emergency_hold_task = nil

        self.current_mission = self.suspended_mission
        self.progress = self.suspended_progress or {}
        self.suspended_mission = nil
        self.suspended_progress = nil
        self.last_poll_day = nil

        if self.current_mission == nil then
            return
        end

        -- A survive day may have arrived while the chain was paused.
        self:CheckCompletion()
        if self.current_mission ~= nil then
            -- Items gained during the pause count now: collect progress is
            -- peak-holdings, so this can only raise it.
            self:ReconcileInventory()
            if self.current_mission ~= nil then
                self:Sync()
            end
        end
    end)
end

-- Drop the overlay without showing a recovered card. Used by admin jumps and
-- load, where the visible mission is about to be replaced anyway.
function GuidedMissionManager:ClearEmergency()
    if self.emergency_hold_task ~= nil then
        self.emergency_hold_task:Cancel()
        self.emergency_hold_task = nil
    end

    if self.inventory_task ~= nil then
        self.inventory_task:Cancel()
        self.inventory_task = nil
    end

    self.emergency = nil
    self.suspended_mission = nil
    self.suspended_progress = nil
end

function GuidedMissionManager:CheckCompletion()
    -- Emergencies resolve on their stat condition, never on objectives. All of
    -- their rows are optional, so without this guard they would "complete"
    -- immediately and advance the chain.
    if self.emergency ~= nil then
        return
    end

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

    if self.emergency ~= nil then
        local entry = self.emergency
        Netvars.Write(self.inst, {
            title = entry.title,
            subtext = entry.subtext or "",
            hint = entry.hint or "",
            rows = FormatRows(entry, self.progress, false),
            state = "emergency",
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
    -- While an emergency is showing (or its recovered card holds), the chain
    -- mission and its progress are the suspended ones. The emergency itself is
    -- never saved: a load resumes the chain exactly where it was.
    local mission = self.suspended_mission
        or (self.emergency == nil and self.current_mission or nil)
    local progress = self.suspended_progress
        or (self.emergency == nil and self.progress or {})

    return {
        mission_index = self.mission_index,
        mission_id = mission ~= nil and mission.id or nil,
        progress = progress,
        completed = self.completed,
        -- Only "server" frequency survives a load; "session" intentionally
        -- re-arms when the session ends.
        fired_emergencies = Settings.emergency_frequency == "server"
            and self.fired_emergencies or nil,
    }
end

function GuidedMissionManager:OnLoad(data)
    if type(data) ~= "table" then
        return
    end

    -- A load always starts without an overlay; the saved chain mission is the
    -- one OnSave wrote from the suspended fields.
    self:ClearEmergency()

    self.mission_index = tonumber(data.mission_index) or 0
    self.progress = type(data.progress) == "table" and data.progress or {}
    self.completed = data.completed == true
    self.loaded = true

    self.fired_emergencies = {}
    if Settings.emergency_frequency == "server"
        and type(data.fired_emergencies) == "table" then
        self.fired_emergencies = data.fired_emergencies
    end

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

    if self.emergency_hold_task ~= nil then
        self.emergency_hold_task:Cancel()
        self.emergency_hold_task = nil
    end
end

return GuidedMissionManager
