-- Emergency (pop-up) missions.
--
-- These are deliberately separate from the ordered chain in missions.lua. The
-- server manager shows an emergency in place of the active chain mission when
-- its trigger condition is true, then restores the chain mission untouched when
-- its resolve condition is true.
--
-- A condition has the shape
--
--   { kind = "stat", stat = "health", threshold = "<50" }
--
-- The threshold is a string so the comparison is explicit:
--
--   "<50"   below 50%          "<=50"  50% or below
--   ">50"   above 50%          ">=50"  50% or above
--
-- Values are percentages of the stat's maximum (0-100). `kind` is the extension
-- point: new condition kinds are added here and the manager never changes.
--
-- Every emergency objective must set `optional = true`: an emergency resolves on
-- its stat condition, never on objective completion, and a required row would
-- make the manager complete it the moment it starts.

local Conditions = require("guidedmissions/conditions")

local Emergencies = {}

-- Re-exported so the manager, the test harness and mission authors keep one
-- entry point; the implementation lives in conditions.lua.
Emergencies.VALID_STATS = Conditions.VALID_STATS
Emergencies.GetStatFraction = Conditions.GetStatFraction
Emergencies.ParseThreshold = Conditions.ParseThreshold

Emergencies.VALID_KINDS = {
    stat = true,
}

-- Evaluate one condition. Unknown kinds, missing stats and bad thresholds are
-- false rather than errors, so a malformed entry simply never fires.
local function ConditionMet(condition, inst)
    if condition == nil or condition.kind ~= "stat" then
        return false
    end

    local fraction = Conditions.GetStatFraction(inst, condition.stat)
    if fraction == nil then
        return false
    end

    local operator, value = Conditions.ParseThreshold(condition.threshold)
    if operator == nil then
        return false
    end

    return Conditions.Matches(operator, fraction * 100, value)
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
}

return Emergencies
