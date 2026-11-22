-- Emergency (pop-up) missions.
--
-- These are deliberately separate from the ordered chain in missions.lua. The
-- server manager shows an emergency in place of the active chain mission when
-- its trigger condition is true, then restores the chain mission untouched when
-- its resolve condition is true.
--
-- A stat condition has the shape
--
--   { kind = "stat", stat = "health", threshold = "<50" }
--
-- The threshold is a string so the comparison is explicit:
--
--   "<50"   below 50          "<=50"  50 or below
--   ">50"   above 50          ">=50"  50 or above
--
-- Health, sanity, hunger and wetness use percentages of the stat's maximum
-- (0-100). Temperature uses raw degrees ("<0" for freezing, ">70" for
-- overheating). `kind` is the extension point: new condition kinds are added
-- here and the manager never changes. `kind = "hounds"` covers a hound wave
-- (see HOUND_STATES below), `kind = "cycle"` starts on one world day, and
-- `kind = "kill"` ends when a named creature dies (see below).
--
-- Stat emergencies resolve on their stat condition, never on objective
-- completion, so their rows are display-only. Hound emergencies likewise
-- resolve on world state, so every row (including theirs) is optional.

local GLOBAL = _G

local Conditions = require("guidedmissions/conditions")
local Objectives = require("guidedmissions/objectives")

local Emergencies = {}

-- Re-exported so the manager, the test harness and mission authors keep one
-- entry point; the implementation lives in conditions.lua.
Emergencies.VALID_STATS = Conditions.VALID_STATS
Emergencies.GetStatFraction = Conditions.GetStatFraction
Emergencies.GetStatValue = Conditions.GetStatValue
Emergencies.ParseThreshold = Conditions.ParseThreshold
Emergencies.ParseStatThreshold = Conditions.ParseStatThreshold

Emergencies.VALID_KINDS = {
    stat = true,
    hounds = true,
    cycle = true,
    kill = true,
    ghost = true,
    revived = true,
    ghost_nearby = true,
}

-- Ghost state. `playerghost` is the canonical tag: OnMakePlayerGhost adds it and
-- DoActualRez removes it (docs/dst-api.md, "Player death, ghosts and revival").
-- Health cannot be used: a ghost's health is restored to RESURRECT_HEALTH, so
-- Health:IsDead() is false.
function Emergencies.IsGhost(inst)
    return inst ~= nil and inst.HasTag ~= nil
        and inst:HasTag("playerghost") == true
end

-- While a player is a ghost only the death card is actionable. A dead player's
-- stats are neutralised (health 50, sanity 50, hunger 2/3), and only the ghost
-- trigger describes their situation, so every other entry is ineligible.
function Emergencies.CanTriggerWhileGhost(entry)
    return entry ~= nil and entry.trigger ~= nil
        and entry.trigger.kind == "ghost"
end

-- A living player standing near a dead friend. The ghost does not have to be
-- targeting the helper; DST has no party, so any nearby player ghost counts.
-- The trigger and clear radii differ so a ghost drifting on the edge does not
-- flap the card on and off.
local GHOST_TRIGGER_RADIUS = 20
local GHOST_CLEAR_RADIUS = 25

local function HasNearbyGhost(inst, radius)
    if inst == nil or Emergencies.IsGhost(inst) then
        return false
    end
    local players = GLOBAL.AllPlayers
    if players == nil or #players < 2 then
        return false
    end
    local sim = GLOBAL.TheSim
    local transform = inst.Transform
    if sim == nil or transform == nil then
        return false
    end

    local x, y, z = transform:GetWorldPosition()
    local entities = sim:FindEntities(x, y, z, radius, { "playerghost" })
    for _, entity in ipairs(entities or {}) do
        if entity ~= inst and (entity.IsValid == nil or entity:IsValid()) then
            return true
        end
    end
    return false
end

local GHOST_NEARBY_STATES = {
    nearby = function(inst)
        return HasNearbyGhost(inst, GHOST_TRIGGER_RADIUS)
    end,
    clear = function(inst)
        return not HasNearbyGhost(inst, GHOST_CLEAR_RADIUS)
    end,
}

Emergencies.VALID_GHOST_STATES = {
    nearby = true,
    clear = true,
}

-- Hound waves. The world's `hounded` component (scripts/components/hounded.lua)
-- enters a warning state 30-120 seconds before hounds spawn and pushes
-- `houndwarning` on each targeted player at that moment -- the bark a character
-- answers with ANNOUNCE_HOUNDS. There is no "wave over" event, so `clear` is
-- derived from world state plus a proximity scan for living hound-tagged
-- creatures. See docs/dst-api.md, "Hound waves".
--
-- `state` is one of:
--
--   "warning"    the shard is in the pre-attack warning (first bark)
--   "attacking"  the wave is spawning hounds
--   "nearby"     at least one living, non-pet hound stands near the player
--   "clear"      none of the above: safe to close the card
--
-- The scan radius is comfortably beyond the 30-unit hound spawn distance.
local HOUND_RADIUS = 60

local function GetHounded()
    local world = GLOBAL.TheWorld
    return world ~= nil and world.components ~= nil
        and world.components.hounded or nil
end

local function HoundsNearby(inst)
    local sim = GLOBAL.TheSim
    local transform = inst ~= nil and inst.Transform or nil
    if sim == nil or transform == nil then
        return false
    end

    local x, y, z = transform:GetWorldPosition()
    local entities = sim:FindEntities(x, y, z, HOUND_RADIUS, { "hound" })
    for _, entity in ipairs(entities or {}) do
        local valid = entity.IsValid == nil or entity:IsValid()
        -- Walrus Camp hounds carry `pet_hound`; they belong to MacTusk, not a
        -- wave, and must not keep the card open.
        local pet = entity.HasTag ~= nil and entity:HasTag("pet_hound")
        local health = entity.components ~= nil and entity.components.health or nil
        local dead = health ~= nil and health.IsDead ~= nil and health:IsDead()
        if valid and not pet and not dead then
            return true
        end
    end
    return false
end

local HOUND_STATES = {
    warning = function(_)
        local hounded = GetHounded()
        return hounded ~= nil and hounded.GetWarning ~= nil
            and hounded:GetWarning() == true
    end,
    attacking = function(_)
        local hounded = GetHounded()
        return hounded ~= nil and hounded.GetAttacking ~= nil
            and hounded:GetAttacking() == true
    end,
    nearby = HoundsNearby,
    clear = function(inst)
        -- Warning and spawn-in both precede the fight; close only once the
        -- hounds are actually gone.
        local hounded = GetHounded()
        if hounded ~= nil
            and hounded.GetWarning ~= nil and hounded:GetWarning() then
            return false
        end
        if hounded ~= nil
            and hounded.GetAttacking ~= nil and hounded:GetAttacking() then
            return false
        end
        return not HoundsNearby(inst)
    end,
}

Emergencies.VALID_HOUND_STATES = {
    warning = true,
    attacking = true,
    nearby = true,
    clear = true,
}

-- Boss availability for `boss`-guarded cycle triggers. A world setting of
-- "Never" for Deerclops sets `TUNING.SPAWN_DEERCLOPS = false` before the world
-- is created (`worldsettings_overrides.lua`, `applyoverrides_pre.deerclops`),
-- and the spawner component exists only on the forest shard -- so the card must
-- not appear for a boss that cannot show up. The attack count also has to be
-- positive, for mods that zero it. See docs/dst-api.md, "Deerclops spawner".
local BOSS_ENABLED = {
    deerclops = function()
        local tuning = GLOBAL.TUNING
        local world = GLOBAL.TheWorld
        return tuning ~= nil
            and tuning.SPAWN_DEERCLOPS ~= false
            and (tonumber(tuning.DEERCLOPS_ATTACKS_PER_SEASON) or 0) > 0
            and world ~= nil and world.components ~= nil
            and world.components.deerclopsspawner ~= nil
    end,
}

-- Exported for mission-data validation in tests/manager_test.lua.
Emergencies.VALID_BOSSES = {
    deerclops = true,
}

-- Cycle triggers. `day` is the 1-based world day the HUD shows (the same
-- `day` a `survive` objective names), not the engine's completed-cycle count:
-- day 1 is `cycles == 0`. It fires while that day is current -- the manager
-- polls every second and the world-state `cycles` watcher pops it at dawn, so
-- in practice it fires at the start of the day. Equality is deliberate: a
-- player who joins after the day has passed does not get a late card. An
-- optional `boss` gates the whole trigger on that boss being enabled.
local function CycleMatches(condition)
    local day = tonumber(condition.day)
    if day == nil or Objectives.GetCurrentDay() ~= day then
        return false
    end
    if condition.boss ~= nil then
        local enabled = BOSS_ENABLED[condition.boss]
        return enabled ~= nil and enabled()
    end
    return true
end

-- Kill resolves. The state records the prefab ids of entities that died while
-- the card was up; the manager fills it from the world's `entity_death` event,
-- which fires for every death whoever caused it (a player, a tentacle, fire,
-- drowning, starvation). Any death of the named prefab satisfies the resolve.
-- With `or_gone`, a boss removal (`hasslerremoved`: it left or despawned, for
-- example when winter ends) also satisfies it, so the card cannot stick around
-- after the threat has gone.
local function KillMatches(condition, state)
    if condition.prefab == nil or state == nil then
        return false
    end
    if state.kills ~= nil and state.kills[condition.prefab] == true then
        return true
    end
    return condition.or_gone == true and state.gone ~= nil
        and state.gone[condition.prefab] == true
end

-- Per-showing state for event-driven conditions. The manager creates one when
-- it activates an entry and discards it on resolve/clear; it is never saved,
-- because an interrupted emergency is forgotten. `kills` is a set of prefab
-- ids seen dead since activation; `gone` is a set of boss prefabs removed
-- (left, despawned or removed).
function Emergencies.NewState()
    return { kills = {}, gone = {} }
end

-- Feed a world event into an active emergency's state. `entity_death` carries
-- the victim in `data.inst`; `hasslerremoved` carries the entity itself as the
-- payload (pushed by the boss prefab's OnRemove). Other events are ignored.
function Emergencies.NoteEvent(state, event, data)
    if state == nil then
        return
    end
    if event == "entity_death" then
        local victim = data ~= nil and data.inst or nil
        local prefab = victim ~= nil and victim.prefab or nil
        if prefab ~= nil and state.kills ~= nil then
            state.kills[prefab] = true
        end
    elseif event == "hasslerremoved" then
        local prefab = type(data) == "table" and data.prefab or nil
        if prefab ~= nil and state.gone ~= nil then
            state.gone[prefab] = true
        end
    end
end

-- Evaluate one condition. Unknown kinds, missing stats, bad thresholds and
-- unknown hound states are false rather than errors, so a malformed entry
-- simply never fires.
local function ConditionMet(condition, inst, state)
    if condition == nil then
        return false
    end

    if condition.kind == "hounds" then
        local matches = HOUND_STATES[condition.state]
        return matches ~= nil and matches(inst) == true
    end

    if condition.kind == "cycle" then
        return CycleMatches(condition)
    end

    if condition.kind == "kill" then
        return KillMatches(condition, state)
    end

    if condition.kind == "ghost" then
        return Emergencies.IsGhost(inst)
    end

    if condition.kind == "revived" then
        return not Emergencies.IsGhost(inst)
    end

    if condition.kind == "ghost_nearby" then
        local matches = GHOST_NEARBY_STATES[condition.state]
        return matches ~= nil and matches(inst) == true
    end

    if condition.kind ~= "stat" then
        return false
    end

    local stat_value = Conditions.GetStatValue(inst, condition.stat)
    if stat_value == nil then
        return false
    end

    local operator, threshold =
        Conditions.ParseStatThreshold(condition.stat, condition.threshold)
    if operator == nil then
        return false
    end

    return Conditions.Matches(operator, stat_value, threshold)
end

function Emergencies.IsTriggered(entry, inst)
    return entry ~= nil and entry.trigger ~= nil and ConditionMet(entry.trigger, inst)
end

function Emergencies.IsResolved(entry, inst, state)
    return entry ~= nil and entry.resolve ~= nil
        and ConditionMet(entry.resolve, inst, state)
end

Emergencies.entries = {
    {
        -- Death. Shown in place of whatever card was up (a stat/hound card is
        -- not actionable while dead), and resolved the moment the ghost tag
        -- clears. `always`: this is the one card a player needs on every death.
        id = "emergency_death",
        title = "Restless Spirit",
        subtext = "You're a ghost. Any one of these can revive you.",
        resolved_subtext = "Back among the living.",
        hint = "Effigies show a revive button above your health badge. Hearts need a friend.",
        frequency = "always",
        trigger = { kind = "ghost" },
        resolve = { kind = "revived" },
        objectives = {
            -- First when portal resurrection is on (Relaxed/Endless set the
            -- world setting; see docs/dst-api.md). A tag, not a prefab: the
            -- Florid Postern and its Celestial Portal upgrade both carry
            -- `multiplayer_portal`.
            { type = "haunt", tag = "multiplayer_portal", icon = "multiplayer_portal",
              label = "Haunt the Florid Postern",
              when = { setting = "portal_rez" }, optional = true },
            { type = "haunt", prefab = "resurrectionstone",
              label = "Haunt a Touch Stone", optional = true },
            { type = "haunt", prefab = "amulet",
              label = "Haunt a Life Giving Amulet", optional = true },
            { type = "tip", icon = "resurrectionstatue", label = "Activate your Meat Effigy", optional = true },
        },
    },
    {
        id = "emergency_low_health",
        title = "Bleeding Out",
        subtext = "Heal up before something finishes the job.",
        resolved_subtext = "You're stable again.",
        hint = "You can also eat Trail Mix, Pierogi or Fishsticks from the crock pot.",
        trigger = { kind = "stat", stat = "health", threshold = "<50" },
        resolve = { kind = "stat", stat = "health", threshold = ">=75" },
        objectives = {
            { type = "reach_stat", stat = "health", threshold = ">=75", label = "Get back to 75% health" },
            { type = "craft", prefab = "healingsalve", count = 1, label = "Craft a Healing Salve", optional = true },
            { type = "eat", prefab = "butterflywings", count = 1, label = "Eat a butterfly wing", optional = true,
              overrides = {
                  wathgrithr = { type = "eat", prefab = "meat_dried", count = 1, label = "Eat Jerky" },
                  warly = { type = "eat", prefab = "trailmix", count = 1, label = "Eat Trail Mix" },
                  wormwood = { type = "fertilize", self = true, count = 1, label = "Fertilize yourself" },
              } },
            { type = "sleep", count = 1, label = "Sleep in a tent", optional = true,
              overrides = {
                  wickerbottom = { type = "eat", prefab = "trailmix", count = 1, label = "Eat Trail Mix" },
              } },
        },
    },
    {
        id = "emergency_low_sanity",
        title = "Losing Your Grip",
        subtext = "Your mind is fraying. Do something calming.",
        resolved_subtext = "The whispers fade.",
        hint = "You can also prototype new recipes or pick flowers for a quick boost.",
        trigger = { kind = "stat", stat = "sanity", threshold = "<50" },
        resolve = { kind = "stat", stat = "sanity", threshold = ">=75" },
        objectives = {
            { type = "reach_stat", stat = "sanity", threshold = ">=75", label = "Get back to 75% sanity" },
            { type = "eat", prefab = "green_cap_cooked", count = 1, label = "Eat a Cooked Green Cap", optional = true,
              overrides = {
                  wathgrithr = { type = "pick", prefab = "flower", count = 1, label = "Pick a flower" },
                  warly = { type = "pick", prefab = "flower", count = 1, label = "Pick a flower" },
              } },
            { type = "eat", prefab = "cactus_meat_cooked", count = 1, label = "Eat some Cooked Cactus Flesh", optional = true,
              overrides = {
                  wathgrithr = { type = "prototype", count = 1, label = "Prototype something new" },
                  warly = { type = "prototype", count = 1, label = "Prototype something new" },
              } },
            { type = "craft", prefab = "tophat", count = 1, label = "Craft a Top Hat", optional = true },
            { type = "sleep", count = 1, label = "Sleep in a tent", optional = true,
              overrides = {
                  wickerbottom = { type = "prototype", count = 1, label = "Prototype something new" },
              } },
        },
    },
    {
        id = "emergency_low_hunger",
        title = "Running on Empty",
        subtext = "Your stomach is empty. Go find something to eat.",
        resolved_subtext = "You're fed again.",
        hint = "Go exploring to find some wild carrot or berries.",
        trigger = { kind = "stat", stat = "hunger", threshold = "<25" },
        resolve = { kind = "stat", stat = "hunger", threshold = ">=70" },
        objectives = {
            { type = "reach_stat", stat = "hunger", threshold = ">=70", label = "Get back to 70% hunger" },
            { type = "eat", prefab = "berries_cooked", count = 1, label = "Cook & eat some berries", optional = true,
              overrides = {
                  wathgrithr = { type = "eat", prefab = "cookedmeat", count = 1, label = "Eat cooked meat" },
                  warly = false,
              } },
            { type = "trap_catch", count = 1, label = "Catch something in a trap", optional = true },
            { type = "cookpot", prefab = "meatballs", count = 1, label = "Cook meatballs", optional = true },
        },
    },
    {
        id = "emergency_freezing",
        title = "Freezing Cold",
        subtext = "You're freezing. Get warm before you lose health.",
        resolved_subtext = "You're warm again.",
        hint = "Stand by a fire, wear winter clothing, and use a Thermal Stone.",
        -- DST's freezing line is temperature < 0 (Temperature:IsFreezing).
        trigger = { kind = "stat", stat = "temperature", threshold = "<5" },
        resolve = { kind = "stat", stat = "temperature", threshold = ">=15" },
        objectives = {
            { type = "reach_stat", stat = "temperature", threshold = ">=15", label = "Warm up to 15°" },
            { type = "equip", prefab = "winterhat", label = "Wear a Winter Hat", optional = true },
            { type = "collect", prefab = "heatrock", count = 1, label = "Grab a Thermal Stone", optional = true },
            { type = "build", prefab = "campfire", count = 1, label = "Build a campfire to heat up", optional = true },
        },
    },
    {
        id = "emergency_overheating",
        title = "Heatstroke",
        subtext = "You're overheating. Cool down before you pass out.",
        resolved_subtext = "You're cooling down.",
        hint = "Stand under a tree, go in the caves or use a Thermal Stone.",
        -- DST's overheat line is temperature > overheattemp (70 by default).
        trigger = { kind = "stat", stat = "temperature", threshold = ">65" },
        resolve = { kind = "stat", stat = "temperature", threshold = "<=30" },
        objectives = {
            { type = "reach_stat", stat = "temperature", threshold = "<=30", label = "Cool down to 30°" },
            { type = "eat", prefab = "ice", count = 1, label = "Eat Ice", optional = true },
            { type = "equip", prefab = "minifan", label = "Equip a Whirly Fan", optional = true },
            { type = "build", prefab = "coldfire", count = 1, label = "Build Endothermic Fire", optional = true },
        },
    },
    {
        id = "emergency_wet",
        title = "Drenched",
        subtext = "Soaked! Dry off before you freeze or go crazy.",
        resolved_subtext = "You're dry again.",
        hint = "Stand by a fire while wearing waterproof gear to quickly dry up.",
        -- DST marks a player "wet" at 2 of 5 moisture segments (40%); this fires
        -- once they are properly soaked, with a wide gap back to dry.
        trigger = { kind = "stat", stat = "wetness", threshold = ">50" },
        resolve = { kind = "stat", stat = "wetness", threshold = "<=10" },
        objectives = {
            { type = "reach_stat", stat = "wetness", threshold = "<=10", label = "Dry off to 10%" },
            { type = "equip", prefab = "umbrella", label = "Equip an Umbrella", optional = true },
            { type = "equip", prefab = "strawhat", label = "Equip a Straw Hat", optional = true },
            { type = "tip", icon = "evergreen_normal", label = "Stand under a tree" }
        },
    },
    {
        id = "emergency_hound_wave",
        title = "Something is Coming...",
        subtext = "This barking sounds rather ominous.",
        resolved_subtext = "The hounds are gone.",
        hint = "Equip a weapon and armor, and fight them one at a time.",
        -- First bark, not the spawn: the warning gives the player time to act.
        trigger = { kind = "hounds", state = "warning" },
        -- No "wave over" event exists, so the card closes once the shard is no
        -- longer warning/spawning and no living wave hound is near the player.
        resolve = { kind = "hounds", state = "clear" },
        objectives = {
            { type = "kill", prefab = "hound", count = 3, label = "Defend yourself", optional = true },
            { type = "equip", prefab = "spear", label = "Equip a spear", optional = true },
            { type = "equip", prefab = "armorwood", label = "Equip a Log Suit", optional = true },
        },
    },
    {
        id = "emergency_deerclops",
        title = "A Cold Welcome",
        subtext = "Winter has a visitor. Don't answer the door.",
        resolved_subtext = "It's gone. Time to rebuild.",
        hint = "Armour, healing and sanity food help. Running away is allowed.",
        -- No card at all when the world setting disables Deerclops (or when
        -- this shard has no spawner). It ends when the Deerclops dies, or when
        -- it leaves/despawns -- which is what happens at winter's end.
        trigger = { kind = "cycle", day = 29, boss = "deerclops" },
        resolve = { kind = "kill", prefab = "deerclops", or_gone = true },
        objectives = {
            { type = "tip", label = "Craft armour" },
            { type = "tip", label = "Have 5-10 healing food ready" },
            { type = "tip", label = "Have a way to restore sanity" },
            { type = "tip", label = "Craft a weapon", optional = true },
        },
    },
    {
        -- The living half of the death card: a player standing next to a ghost
        -- friend. Last in file order so the helper's own danger wins. A ghost
        -- cannot receive an amulet (`ShouldAcceptItem` only takes `reviver`
        -- items), but it can haunt one dropped on the ground, so the hint
        -- distinguishes giving the heart from dropping the amulet.
        id = "emergency_ghost_friend",
        title = "A Friend in Need",
        subtext = "A friend is a ghost. They need your help.",
        resolved_subtext = "No ghosts nearby.",
        hint = "The ghost can't take items: give the heart, drop the amulet to haunt.",
        frequency = "always",
        trigger = { kind = "ghost_nearby", state = "nearby" },
        resolve = { kind = "ghost_nearby", state = "clear" },
        objectives = {
            { type = "craft", prefab = "reviver", count = 1,
              label = "Craft a Telltale Heart", optional = true },
            { type = "craft", prefab = "amulet", count = 1,
              label = "Craft a Life Giving Amulet", optional = true },
        },
    },
}

return Emergencies
