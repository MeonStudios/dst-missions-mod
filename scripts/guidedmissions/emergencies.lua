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
-- (see HOUND_STATES below).
--
-- Stat emergencies resolve on their stat condition, never on objective
-- completion, so their rows are display-only. Hound emergencies likewise
-- resolve on world state, so every row (including theirs) is optional.

local GLOBAL = _G

local Conditions = require("guidedmissions/conditions")

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

-- Evaluate one condition. Unknown kinds, missing stats, bad thresholds and
-- unknown hound states are false rather than errors, so a malformed entry
-- simply never fires.
local function ConditionMet(condition, inst)
    if condition == nil then
        return false
    end

    if condition.kind == "hounds" then
        local matches = HOUND_STATES[condition.state]
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

function Emergencies.IsResolved(entry, inst)
    return entry ~= nil and entry.resolve ~= nil and ConditionMet(entry.resolve, inst)
end

Emergencies.entries = {
    {
        id = "emergency_low_health",
        title = "Bleeding Out",
        subtext = "Patch yourself up before something finishes the job.",
        resolved_subtext = "You're stable again.",
        hint = "You can also eat Trail Mix, Pierogi or Fishsticks from the crock pot.",
        trigger = { kind = "stat", stat = "health", threshold = "<50" },
        resolve = { kind = "stat", stat = "health", threshold = ">=75" },
        objectives = {
            -- Required goal row: matches `resolve`, so the card says what will
            -- end the emergency. It is live (current percentage), not a count.
            { type = "reach_stat", stat = "health", threshold = ">=75", label = "Get back to 75% health" },
            { type = "craft", prefab = "healingsalve", count = 1, label = "Craft a Healing Salve", optional = true },
            { type = "eat", prefab = "butterflywings", count = 1, label = "Eat a butterfly wing", optional = true },
            { type = "sleep", count = 1, label = "Sleep in a tent", optional = true },
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
            { type = "eat", prefab = "green_cap_cooked", count = 1, label = "Eat a Cooked Green Cap", optional = true },
            { type = "eat", prefab = "cactus_meat_cooked", count = 1, label = "Eat some Cooked Cactus Flesh", optional = true },
            { type = "craft", prefab = "tophat", count = 1, label = "Craft a Top Hat", optional = true },
            { type = "sleep", count = 1, label = "Sleep in a tent", optional = true },
        },
    },
    {
        id = "emergency_low_hunger",
        title = "Running on Empty",
        subtext = "Your stomach is empty. Go find something to eat.",
        resolved_subtext = "You're fed again.",
        hint = "Go exploring to find some wild carrot or berries.",
        -- Low enough to mean danger (starvation damage starts at 0), with a
        -- wide gap back to 50% so eating one meal does not re-arm it instantly.
        trigger = { kind = "stat", stat = "hunger", threshold = "<25" },
        resolve = { kind = "stat", stat = "hunger", threshold = ">=70" },
        objectives = {
            { type = "reach_stat", stat = "hunger", threshold = ">=70", label = "Get back to 70% hunger" },
            { type = "eat", prefab = "berries_cooked", count = 1, label = "Cook & eat some berries", optional = true },
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
}

return Emergencies
