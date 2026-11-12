-- Shared stat/threshold parsing for emergency conditions and `reach_stat`
-- objectives. Keeping one implementation means an emergency's resolve condition
-- and its required goal row cannot disagree.
--
-- A threshold is a string so the comparison is explicit:
--
--   "<50"   below 50%          "<=50"  50% or below
--   ">50"   above 50%          ">=50"  50% or above
--
-- Values are percentages of the stat's maximum (0-100).

local Conditions = {}

Conditions.VALID_STATS = {
    health = true,
    sanity = true,
}

-- The player's stat as a fraction of its maximum, or nil when the component or
-- its fields are missing. Raw fields are used deliberately: Sanity:GetPercent()
-- is forced to 0/1 under induced insanity/lunacy, which would hide a real drop.
function Conditions.GetStatFraction(inst, stat)
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
        return current / max
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
        return current / max
    end

    return nil
end

local COMPARATORS = {
    ["<"] = function(a, b) return a < b end,
    ["<="] = function(a, b) return a <= b end,
    [">"] = function(a, b) return a > b end,
    [">="] = function(a, b) return a >= b end,
}

-- Parse a threshold string into an operator and a 0-100 value. Returns nil for
-- malformed strings or values outside that range.
function Conditions.ParseThreshold(text)
    if type(text) ~= "string" then
        return nil
    end

    local operator, number = text:match("^%s*([<>]=?)%s*(%d+%.?%d*)%s*$")
    if operator == nil then
        return nil
    end

    local value = tonumber(number)
    if value == nil or value < 0 or value > 100 then
        return nil
    end

    return operator, value
end

-- Compare a 0-100 value against a parsed threshold. A bad operator is false.
function Conditions.Matches(operator, value, threshold)
    local compare = COMPARATORS[operator]
    return compare ~= nil and compare(value, threshold)
end

return Conditions
