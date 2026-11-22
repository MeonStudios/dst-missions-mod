-- See netvars.lua: require()d modules cannot see modmain's `GLOBAL` binding.
local GLOBAL = _G

local Missions = require("guidedmissions/missions")
local Emergencies = require("guidedmissions/emergencies")
local Objectives = require("guidedmissions/objectives")
local Netvars = require("guidedmissions/netvars")
local Settings = require("guidedmissions/settings")
local Strings = require("guidedmissions/strings")
local L10n = require("guidedmissions/l10n")

local HOLD_SECONDS = 3

local function FindMissionIndexById(id)
    for i, mission in ipairs(Missions) do
        if mission.id == id then
            return i
        end
    end
    return nil
end

-- The shard's persistent world-session id (`TheWorld.meta.session_identifier`,
-- generated at worldgen; the "Begin Session" value in the logs). It identifies
-- the *shard*, not the server run, which is exactly what a migration record
-- names in its `sessionid` field (components/playerspawner.lua:87-95). Comparing
-- the two is how OnLoad tells a live shard transfer from a stale migration
-- record left in a save file -- see OnLoad and docs/dst-api.md.
local function WorldSessionId()
    local world = GLOBAL.TheWorld
    return world ~= nil and world.meta ~= nil and world.meta.session_identifier or nil
end

local function HasSurviveObjective(objectives)
    for _, objective in ipairs(objectives or {}) do
        if objective.type == "survive" then
            return true
        end
    end
    return false
end

-- Rows are `label|prefab|counter|done|optional`, joined by `;`, so the
-- separators must never appear inside the free-form label. A survive row appends
-- `|day|current|target` (fields 6-8) so the client can render the day counter in
-- its own language; every other row stays five fields. The label and counter are
-- SOURCE text: the client translates the label at render time.
local function SanitiseLabel(text)
    return (tostring(text):gsub("[|;]", " "))
end

-- Pack the resolved objectives into the client's row format. Required rows
-- are emitted before optional ones regardless of authoring order, so the HUD
-- can draw one "Optional" heading above the second group. `force_done` renders
-- the required rows as complete for the 3-second completion hold; optional
-- rows keep their real state so an unfinished one never shows a check.
local function FormatRows(objectives, progress, force_done)
    local rows = {}
    for pass = 1, 2 do
        local want_optional = pass == 2
        for i, objective in ipairs(objectives or {}) do
            local optional = Objectives.IsOptional(objective)
            -- A `when` gate hides the row server-side, so the client never
            -- draws (or counts) a row that cannot apply in this world.
            if optional == want_optional and Objectives.IsAvailable(objective) then
                local value = progress[i] or 0
                local done = ((force_done and not optional)
                    or Objectives.IsComplete(objective, value)) and 1 or 0
                local fields = {
                    SanitiseLabel(Objectives.GetLabel(objective)),
                    Objectives.GetIconPrefab(objective) or "",
                    Objectives.GetCounter(objective, value),
                    tostring(done),
                    optional and "1" or "0",
                }
                local kind, current, target =
                    Objectives.GetCounterMeta(objective, value)
                if kind ~= "" then
                    fields[#fields + 1] = kind
                    fields[#fields + 1] = tostring(current)
                    fields[#fields + 1] = tostring(target)
                end
                rows[#rows + 1] = table.concat(fields, "|")
            end
        end
    end
    return table.concat(rows, ";")
end

local GuidedMissionManager = Class(function(self, inst)
    self.inst = inst
    self.mission_index = 0
    self.current_mission = nil
    -- The active mission's objective rows resolved for this player's character
    -- (see Objectives.ResolveAll). Every progress/match/render loop reads this,
    -- never `mission.objectives`, so a character override is applied exactly
    -- once per activation.
    self.objectives = {}
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
    -- `fired_emergencies` remembers ids whose recovered card has been shown;
    -- whether that survives a load depends on Settings.emergency_frequency
    -- (see OnSave/OnLoad).
    self.emergency = nil
    self.suspended_mission = nil
    self.suspended_progress = nil
    self.suspended_objectives = nil
    self.fired_emergencies = {}
    -- Per-showing state for event-driven resolve conditions (a `kill` records
    -- victims). Created by ActivateEmergency, dropped on resolve/clear.
    self.emergency_state = nil
    -- Pending 3-second recovered-card hold (see ResolveEmergency).
    self.emergency_hold_task = nil

    -- Inventory-derived objectives (collect, collect_food, craft) are reread
    -- from the inventory, never accumulated from events -- but an event is
    -- still what triggers the reread. These four cover every way an item joins
    -- the inventory; see Objectives.ReconcileProgress and docs/dst-api.md.
    -- `craft` also keeps its `builditem` credit (it listens below); the reread
    -- makes a row complete when the item is already carried. Inventory-item
    -- recipes (torch) fire `builditem`; structures (firepit, researchlab) fire
    -- `buildstructure` instead. See objectives.lua.
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
    -- `deployitem` is vanilla: `Deployable:Deploy` pushes it on the deployer
    -- with the item's prefab (components/deployable.lua:132-142), covering
    -- deployables such as the Garden Digamajig and bird traps. Placing a
    -- structure from the build menu is `buildstructure` instead.
    inst:ListenForEvent("deployitem", function(_, data)
        self:OnObjectiveEvent("deployitem", data)
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
    -- Hunger decays on a 1 Hz task and pushes `hungerdelta` every time
    -- (`components/hunger.lua`, SetCurrent), so this also keeps a live
    -- `reach_stat` hunger row current between polls.
    inst:ListenForEvent("hungerdelta", function(_, data)
        self:OnObjectiveEvent("hungerdelta", data)
        self:CheckEmergencies()
    end)
    -- Wetness (moisture) and temperature call SetTemperature/DoDelta every
    -- frame, so their `*delta` events are far too frequent to forward. The 1 Hz
    -- poll reads both; these cheap threshold-crossing events just let the stock
    -- freezing/overheating emergencies pop the moment they cross.
    inst:ListenForEvent("startfreezing", function(_, _)
        self:CheckEmergencies()
    end)
    inst:ListenForEvent("stopfreezing", function(_, _)
        self:CheckEmergencies()
    end)
    inst:ListenForEvent("startoverheating", function(_, _)
        self:CheckEmergencies()
    end)
    inst:ListenForEvent("stopoverheating", function(_, _)
        self:CheckEmergencies()
    end)
    -- Hound waves push `houndwarning` on each targeted player as the warning
    -- starts (scripts/components/hounded.lua, DoWarningSound) -- the first
    -- bark. The hound condition reads world state and the 1 Hz poll would catch
    -- it anyway; this just pops the card immediately.
    inst:ListenForEvent("houndwarning", function(_, _)
        self:CheckEmergencies()
    end)
    -- A `cycle` trigger names a world day. WatchWorldState invokes watchers
    -- after the worldstate component has stored the new value
    -- (components/worldstate.lua SetVariable), so the condition reads the new
    -- day; the 1 Hz poll remains the fallback for a player joining mid-day.
    inst:WatchWorldState("cycles", function(_, _)
        self:CheckEmergencies()
    end)
    -- Every entity death is pushed on TheWorld before the victim's own `death`
    -- event (`components/health.lua` Health:SetVal), whoever caused it: a
    -- player, a tentacle, fire, drowning or starvation. While an emergency is
    -- up, record the victim so a `kill` resolve can match, and re-check now.
    inst:ListenForEvent("entity_death", function(_, data)
        if self.emergency ~= nil then
            Emergencies.NoteEvent(self.emergency_state, "entity_death", data)
            self:CheckEmergencies()
        end
    end, GLOBAL.TheWorld)
    -- A boss pushes `hasslerremoved` on TheWorld when its entity is removed for
    -- any reason (`prefabs/deerclops.lua` OnRemove) -- after a kill, or when it
    -- leaves at winter's end (`OnStopWinter`/`OnEntitySleep` push
    -- `storehassler` and then remove it). A `kill` resolve with `or_gone`
    -- matches this, so a despawn closes the card as well as a death.
    inst:ListenForEvent("hasslerremoved", function(_, data)
        if self.emergency ~= nil then
            Emergencies.NoteEvent(self.emergency_state, "hasslerremoved", data)
            self:CheckEmergencies()
        end
    end, GLOBAL.TheWorld)
    -- `equip`/`unequip` drive live `equip` objectives: the row mirrors the
    -- current equipment slots, so it checks while the item is worn and unchecks
    -- when it is removed. Vanilla pushes both on the inventory's owner
    -- (scripts/components/inventory.lua) after updating `equipslots`.
    inst:ListenForEvent("equip", function(_, data)
        self:OnObjectiveEvent("equip", data)
    end)
    inst:ListenForEvent("unequip", function(_, data)
        self:OnObjectiveEvent("unequip", data)
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
    -- Pushed by modmain's `fertilizable` post-init when a player fertilizes
    -- themself (Wormwood); `data.fertilizer` is the item's prefab.
    inst:ListenForEvent("guidedmissions_self_fertilized", function(_, data)
        self:OnObjectiveEvent("guidedmissions_self_fertilized", data)
    end)
    inst:ListenForEvent("unlockrecipe", function(_, data)
        self:OnUnlockRecipe(data)
    end)
    -- Ghost state and revival. Both are pushed on the player server-side
    -- (prefabs/player_common_extensions.lua): `ms_becameghost` after the tag and
    -- health are swapped, `ms_respawnedfromghost` after the tag is removed.
    -- They make the death card pop and resolve on the same frame instead of on
    -- the next poll; the poll remains the fallback for a load-as-ghost.
    inst:ListenForEvent("ms_becameghost", function(_, _)
        self:CheckEmergencies()
    end)
    inst:ListenForEvent("ms_respawnedfromghost", function(_, _)
        self:CheckEmergencies()
    end)
    -- A successful ghost haunt (ACTIONS.HAUNT.fn) credits `haunt` rows with the
    -- haunted entity.
    inst:ListenForEvent("haunt", function(_, data)
        self:OnObjectiveEvent("haunt", data)
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
        -- Emergencies fire after the chain is finished too: a finished player
        -- can still be dying, frozen or next to a friend's ghost.
        self:CheckEmergencies()
        return
    end

    if self.loaded and self.mission_index >= 1 then
        self.current_mission = Missions[self.mission_index]
        if self.current_mission == nil then
            self.completed = true
            self.mission_index = #Missions + 1
            self.objectives = {}
        else
            self.objectives = Objectives.ResolveAll(
                self.current_mission.objectives, self.inst.prefab)
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
        self.objectives = {}
        self.progress = {}
        self.completed = true
        self:Sync()
        -- Chat is composed by the server, so it uses the server's locale.
        self:Announce(L10n.Lfmt(Strings.ALL_COMPLETE_CHAT, self.inst:GetDisplayName()))
        return
    end

    self.completed = false
    self.current_mission = mission
    -- Resolve character overrides once; every later loop reads this list.
    self.objectives = Objectives.ResolveAll(mission.objectives, self.inst.prefab)
    self.progress = {}
    self.last_poll_day = nil

    for i, objective in ipairs(self.objectives) do
        self.progress[i] = Objectives.InitialProgress(self.inst, objective)
    end

    self:Sync()
    -- Server log only: the HUD already shows the mission, and announcing every
    -- start would spam chat (especially with /setmission).
    self:Log(L10n.Lfmt(
        Strings.MISSION_START_FMT,
        self.inst:GetDisplayName(),
        index,
        L10n.L(mission.title)
    ))

    -- A freshly activated mission can already be satisfied (for example, a
    -- survival objective whose day has passed).
    self:CheckCompletion()
end

function GuidedMissionManager:OnObjectiveEvent(event, data)
    -- A finished chain still tracks an active emergency's rows (the helper
    -- card's craft rows), so `completed` alone must not stop objective events.
    if (self.completed and self.emergency == nil) or self.current_mission == nil then
        return
    end

    local changed = false
    for i, objective in ipairs(self.objectives) do
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
    if (self.completed and self.emergency == nil) or self.current_mission == nil
        or self.inventory_task ~= nil then
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
    if (self.completed and self.emergency == nil) or self.current_mission == nil then
        return
    end

    local changed = false
    for i, objective in ipairs(self.objectives) do
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

-- Keep live rows current: `reach_stat` follows the live stat, and a `shared`
-- build row counts equivalent structures standing nearby in Multiplayer Mode.
-- Called from stat events, at Begin, and once per second; this is why the
-- required goal row on an emergency card always matches the value that resolves
-- it, and why a shared row checks as soon as a teammate's structure is in range.
function GuidedMissionManager:RefreshLiveObjectives()
    local mission = self.current_mission
    if mission == nil then
        return
    end

    local changed = false
    for i, objective in ipairs(self.objectives) do
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
    -- Refresh live stat rows first so a silent recovery updates the required
    -- goal row before CheckEmergencies writes the resolved card. This also runs
    -- for a finished chain: an emergency can still be showing or fire.
    self:RefreshLiveObjectives()
    self:CheckEmergencies()
    -- A resolved emergency is showing its recovered card for a moment; nothing
    -- else should touch the tracker until it restores the chain mission.
    if self.completed or self.current_mission == nil or self.emergency ~= nil then
        return
    end

    if not HasSurviveObjective(self.objectives) then
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

-- The global EMERGENCY_FREQUENCY can be overridden per entry (`frequency` on
-- the entry). "always" ignores the fired set entirely; "session" and "server"
-- remember resolved ids (the latter in the save).
local function FrequencyOf(entry)
    return entry ~= nil and entry.frequency or Settings.emergency_frequency
end

function GuidedMissionManager:EmergencyAlreadyFired(entry)
    return entry ~= nil and FrequencyOf(entry) ~= "always"
        and self.fired_emergencies[entry.id] == true
end

-- Called from ResolveEmergency, not from ActivateEmergency: an entry counts as
-- seen only once its recovered ("won") card has been shown. A card that is
-- interrupted before it resolves -- an admin jump, a save/load, the player
-- leaving -- leaves no trace, so the emergency can fire again later.
function GuidedMissionManager:MarkEmergencyFired(entry)
    if entry ~= nil and FrequencyOf(entry) ~= "always" then
        self.fired_emergencies[entry.id] = true
    end
end

-- Called on stat/ghost/haunt events, at Begin, and once per second. It both
-- starts an emergency and resolves the active one.
function GuidedMissionManager:CheckEmergencies()
    local ghost = Emergencies.IsGhost(self.inst)

    if self.emergency ~= nil then
        if ghost and not Emergencies.CanTriggerWhileGhost(self.emergency) then
            -- A death supersedes whatever card was up: a stat or hound card is
            -- not actionable while dead, and the death card is what the player
            -- needs. Drop it without the recovered card and pick a new entry.
            self:PreemptEmergency()
        elseif Emergencies.IsResolved(self.emergency, self.inst, self.emergency_state) then
            self:ResolveEmergency()
            return
        else
            return
        end
    end

    -- The manager must be initialised, and a 3-second hold is finishing a card.
    -- Every other state (before mission 1, after the last mission) may show an
    -- emergency: they fire whenever they apply.
    if not self.started or self.hold_task ~= nil
        or self.emergency_hold_task ~= nil then
        return
    end

    -- The instant between the fatal damage and the ghost conversion still reads
    -- as dead; wait for the tag. (A ghost's health is 50, so this cannot mean
    -- "is a ghost" -- see docs/dst-api.md.)
    local health = self.inst.components ~= nil and self.inst.components.health or nil
    if health ~= nil and health.IsDead ~= nil and health:IsDead() then
        return
    end

    -- First matching entry wins; file order is the tie-breaker. While a ghost,
    -- only ghost-triggered entries are eligible.
    for _, entry in ipairs(Emergencies.entries) do
        if (not ghost or Emergencies.CanTriggerWhileGhost(entry))
            and not self:EmergencyAlreadyFired(entry)
            and Emergencies.IsTriggered(entry, self.inst) then
            self:ActivateEmergency(entry)
            return
        end
    end
end

-- Drop the active card without showing its recovered card and restore the
-- suspended chain, so the next entry can suspend it again. Used only when a
-- death supersedes the card; the entry is not marked as fired.
function GuidedMissionManager:PreemptEmergency()
    if self.emergency == nil then
        return
    end

    self.emergency = nil
    self.emergency_state = nil
    self.current_mission = self.suspended_mission
    self.objectives = self.suspended_objectives or {}
    self.progress = self.suspended_progress or {}
    self.suspended_mission = nil
    self.suspended_progress = nil
    self.suspended_objectives = nil
    self.last_poll_day = nil
    -- If no replacement card activates (all ghost entries already fired this
    -- session), the restored chain card must still reach the client.
    self:Sync()
end

function GuidedMissionManager:ActivateEmergency(entry)
    if entry == nil or self.emergency ~= nil then
        return false
    end

    -- Pause the chain: keep the mission, its resolved rows and its exact
    -- progress table. A finished chain has no mission to pause -- the emergency
    -- simply replaces the all-complete card and Sync puts it back on resolve.
    self.suspended_mission = self.current_mission
    self.suspended_progress = self.progress
    self.suspended_objectives = self.objectives

    -- Not marked as fired here: only a resolved card counts as seen (see
    -- ResolveEmergency).
    self.emergency = entry
    self.emergency_state = Emergencies.NewState()
    self.current_mission = entry
    self.objectives = Objectives.ResolveAll(entry.objectives, self.inst.prefab)
    self.progress = {}
    self.last_poll_day = nil

    for i, objective in ipairs(self.objectives) do
        self.progress[i] = Objectives.InitialProgress(self.inst, objective)
    end

    self:Sync()
    self:Log(L10n.Lfmt(
        Strings.EMERGENCY_START_FMT,
        self.inst:GetDisplayName(),
        L10n.L(entry.title)
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

    -- This is the moment the entry counts as seen: the recovered card is being
    -- shown, so the repeat guard may suppress it from now on.
    self:MarkEmergencyFired(entry)

    Netvars.Write(self.inst, {
        title = entry.title,
        subtext = entry.resolved_subtext or entry.subtext or "",
        hint = "",
        rows = FormatRows(self.objectives, self.progress, false),
        state = "won",
    })

    self.emergency = nil
    self.emergency_state = nil
    self.current_mission = nil
    self.objectives = {}
    self.progress = {}

    self:Log(L10n.Lfmt(
        Strings.EMERGENCY_RESOLVED_FMT,
        self.inst:GetDisplayName(),
        L10n.L(entry.title)
    ))

    if self.emergency_hold_task ~= nil then
        self.emergency_hold_task:Cancel()
        self.emergency_hold_task = nil
    end

    self.emergency_hold_task = self.inst:DoTaskInTime(HOLD_SECONDS, function()
        self.emergency_hold_task = nil

        self.current_mission = self.suspended_mission
        self.objectives = self.suspended_objectives or {}
        self.progress = self.suspended_progress or {}
        self.suspended_mission = nil
        self.suspended_progress = nil
        self.suspended_objectives = nil
        self.last_poll_day = nil

        if self.completed then
            -- The chain was already finished: put the all-complete card back.
            self:Sync()
        elseif self.current_mission ~= nil then
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
        end

        -- A different condition may already apply (or the chain may have just
        -- finished), so give it the chance to pop immediately.
        self:CheckEmergencies()
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
    self.emergency_state = nil
    self.suspended_mission = nil
    self.suspended_progress = nil
    self.suspended_objectives = nil
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

    for i, objective in ipairs(self.objectives) do
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
        rows = FormatRows(self.objectives, self.progress, true),
        state = "won",
    })

    -- Clearing the mission makes objective events and the poller ignore
    -- progress for the duration of the hold.
    self.current_mission = nil
    self.objectives = {}
    self.progress = {}

    self:Announce(L10n.Lfmt(
        Strings.MISSION_COMPLETE_FMT,
        self.inst:GetDisplayName(),
        L10n.L(mission.title)
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
        -- A condition may already apply; let it pop now rather than on the next
        -- poll. (StartMission's own hold, if the mission completes instantly,
        -- suppresses this again.)
        self:CheckEmergencies()
    end)
end

function GuidedMissionManager:Sync()
    -- An emergency can preempt the all-complete card, so it is checked first.
    if self.emergency ~= nil then
        local entry = self.emergency
        Netvars.Write(self.inst, {
            title = entry.title,
            subtext = entry.subtext or "",
            hint = entry.hint or "",
            rows = FormatRows(self.objectives, self.progress, false),
            state = "emergency",
        })
        return
    end

    if self.completed then
        -- Source text, not L(): netvars carry the authored strings and every
        -- client translates them with its own locale.
        Netvars.Write(self.inst, {
            title = Strings.ALL_COMPLETE_TITLE,
            subtext = Strings.ALL_COMPLETE_SUBTEXT,
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
        rows = FormatRows(self.objectives, self.progress, false),
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
        -- "session" must travel with the save too: a shard transfer serializes
        -- the player, and OnLoad decides whether the load starts a new session
        -- or continues one. "always" remembers nothing.
        fired_emergencies = Settings.emergency_frequency ~= "always"
            and self.fired_emergencies or nil,
        -- Stamp the record with the writing shard's world session id. On a live
        -- migration this matches `data.migration.sessionid`; on a save file
        -- that merely *contains* an old migration record it does not (see
        -- OnLoad and docs/dst-api.md -> Shard migration).
        world_session = WorldSessionId(),
    }
end

-- True only when this load is a transfer from a live source shard in the same
-- session. `inst.migration` alone is not enough: player_common writes it back
-- into the save (`data.migration = inst.migration`,
-- prefabs/player_common.lua:1217), and an entity that loaded but never spawned
-- (a client rejected at the mod handshake, or a shutdown mid-transfer) keeps it
-- -- playerspawner clears it only when it spawns the player
-- (components/playerspawner.lua:260). Such a file carries a stale migration
-- payload, and a later fresh join would otherwise keep the previous session's
-- fired set forever.
--
-- A live transfer is serialized by the source shard, so the record's own
-- `world_session` stamp (written by OnSave) equals the `sessionid` the source
-- put in the migration payload (playerspawner.lua:87-95). A stale record was
-- written by a different shard, so the two differ. `worldid` must also name
-- another shard: if it names this one the player is being restored to the shard
-- it was leaving (a failed transfer), which is a relog, not a continuation.
local function IsLiveMigration(inst, data)
    local migration = inst.migration
    local shard = GLOBAL.TheShard
    return migration ~= nil
        and shard ~= nil
        and data.world_session ~= nil
        and data.world_session == migration.sessionid
        and migration.worldid ~= nil
        and migration.worldid ~= shard:GetShardId()
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

    -- "server" keeps the fired set across any load. "session" re-arms on a
    -- fresh join or world load, but keeps it through a shard migration: moving
    -- to the caves and back is still one session. `inst.migration` marks a
    -- migration during OnPreLoad, which runs before component OnLoad
    -- (scripts/prefabs/player_common.lua:1257; scripts/entityscript.lua:1988
    -- vs :2005) -- but on its own it is not proof of a *live* transfer: see
    -- IsLiveMigration.
    self.fired_emergencies = {}
    if type(data.fired_emergencies) == "table" then
        if Settings.emergency_frequency == "server" then
            self.fired_emergencies = data.fired_emergencies
        elseif Settings.emergency_frequency == "session"
            and IsLiveMigration(self.inst, data) then
            self.fired_emergencies = data.fired_emergencies
        end
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
            self.objectives = {}
        else
            self.current_mission = Missions[self.mission_index]
            if self.current_mission == nil then
                self.completed = true
                self.mission_index = #Missions + 1
                self.objectives = {}
            else
                self.objectives = Objectives.ResolveAll(
                    self.current_mission.objectives, self.inst.prefab)
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
