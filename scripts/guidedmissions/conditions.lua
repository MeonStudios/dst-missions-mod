-- Shared stat/threshold parsing for emergency conditions and `reach_stat`
-- objectives. Keeping one implementation means an emergency's resolve condition
-- and its required goal row cannot disagree.
--
-- A threshold is a string so the comparison is explicit:
--
--   "<50"   below 50          "<=50"  50 or below
--   ">50"   above 50          ">=50"  50 or above
--
-- Health, sanity, hunger and wetness are percentages of the stat's maximum
-- (0-100). Temperature is the exception: it is a raw degrees reading, so its
-- thresholds use degrees (for example "<0" for freezing, ">70" for overheating)
-- and may be negative.

local Conditions = {}

Conditions.VALID_STATS = {
    health = true,
    sanity = true,
    hunger = true,
    wetness = true,
    temperature = true,
}

-- Temperature is a raw degree reading, not a percentage. DST clamps players to
-- about -20..90 (TUNING.MIN_ENTITY_TEMP / MAX_ENTITY_TEMP); allow a wider range
-- so tuning or mods that extend it still validate.
local TEMPERATURE_MIN = -100
local TEMPERATURE_MAX = 200

-- Accepted threshold range for a stat, or nil for an unknown stat.
function Conditions.GetStatRange(stat)
    if stat == "temperature" then
        return TEMPERATURE_MIN, TEMPERATURE_MAX
    end
    if Conditions.VALID_STATS[stat] then
        return 0, 100
    end
    return nil
end

-- The unit shown after a live counter ("40/75%", "35/70°").
function Conditions.GetStatUnit(stat)
    return stat == "temperature" and "°" or "%"
end

-- The player's stat in the units its thresholds use: 0-100 for the percentage
-- stats, raw degrees for temperature. Returns nil when the component or its
-- fields are missing. Raw fields are used deliberately: Sanity:GetPercent() is
-- forced to 0/1 under induced insanity/lunacy, which would hide a real drop.
function Conditions.GetStatValue(inst, stat)
    local components = inst ~= nil and inst.components or nil
    if components == nil then
        return nil
    end

    if stat == "health" then
        local health = components.health
        if health == nil then
            return nil
        end
        local current = tonumber(health.currenthealth)
        local max = tonumber(health.maxhealth)
        if current == nil or max == nil or max <= 0 then
            return nil
        end
        return current / max * 100
    end

    if stat == "sanity" then
        local sanity = components.sanity
        if sanity == nil then
            return nil
        end
        local current = tonumber(sanity.current)
        local max = tonumber(sanity.max)
        if current == nil or max == nil or max <= 0 then
            return nil
        end
        return current / max * 100
    end

    if stat == "hunger" then
        local hunger = components.hunger
        if hunger == nil then
            return nil
        end
        local current = tonumber(hunger.current)
        local max = tonumber(hunger.max)
        if current == nil or max == nil or max <= 0 then
            return nil
        end
        return current / max * 100
    end

    if stat == "wetness" then
        -- The DST component is `moisture`; "wetness" is the player-facing name.
        local moisture = components.moisture
        if moisture == nil then
            return nil
        end
        local current = tonumber(moisture.moisture)
        local max = tonumber(moisture.maxmoisture)
        if current == nil or max == nil or max <= 0 then
            return nil
        end
        return current / max * 100
    end

    if stat == "temperature" then
        local temperature = components.temperature
        if temperature == nil then
            return nil
        end
        return tonumber(temperature.current)
    end

    return nil
end

-- Backwards-compatible fraction for the percentage stats. Temperature has no
-- meaningful fraction (its thresholds are degrees), so it returns nil.
function Conditions.GetStatFraction(inst, stat)
    local value = Conditions.GetStatValue(inst, stat)
    if value == nil or stat == "temperature" then
        return nil
    end
    return value / 100
end

local COMPARATORS = {
    ["<"] = function(a, b) return a < b end,
    ["<="] = function(a, b) return a <= b end,
    [">"] = function(a, b) return a > b end,
    [">="] = function(a, b) return a >= b end,
}

-- Operator and raw number, without a range check. Temperature thresholds may
-- be negative.
local function ParseComparison(text)
    if type(text) ~= "string" then
        return nil
    end

    local operator, number = text:match("^%s*([<>]=?)%s*(-?%d+%.?%d*)%s*$")
    if operator == nil then
        return nil
    end

    local value = tonumber(number)
    if value == nil then
        return nil
    end

    return operator, value
end

-- Parse a threshold string into an operator and a 0-100 value. Returns nil for
-- malformed strings or values outside that range.
function Conditions.ParseThreshold(text)
    local operator, value = ParseComparison(text)
    if operator == nil or value < 0 or value > 100 then
        return nil
    end
    return operator, value
end

-- Parse a threshold in the stat's own units: 0-100 for the percentage stats,
-- degrees (-100..200) for temperature. An unknown stat or an out-of-range value
-- returns nil, so a malformed condition simply never fires.
function Conditions.ParseStatThreshold(stat, text)
    local operator, value = ParseComparison(text)
    if operator == nil then
        return nil
    end

    local min, max = Conditions.GetStatRange(stat)
    if min == nil or value < min or value > max then
        return nil
    end

    return operator, value
end

-- Compare a value against a parsed threshold. A bad operator is false.
function Conditions.Matches(operator, value, threshold)
    local compare = COMPARATORS[operator]
    return compare ~= nil and compare(value, threshold)
end

return Conditions
