-- See netvars.lua: require()d modules cannot see modmain's `GLOBAL` binding.
local GLOBAL = _G

local Objectives = {}

-- Labels never carry a count: the tracker renders the counter separately.
local DEFAULT_LABELS = {
    collect = "Collect %s",
    build = "Build %s",
    kill = "Kill %s",
    survive = "Survive until day %d",
}

local function PrefabDisplayName(prefab)
    if prefab == nil then
        return "?"
    end

    local names = GLOBAL.STRINGS and GLOBAL.STRINGS.NAMES
    return (names and names[string.upper(prefab)]) or prefab
end

function Objectives.GetCurrentDay()
    local world = GLOBAL.TheWorld
    -- DST has no `TheWorld.state.day`; the server's world state is
    -- worldstate.data and its day number is `cycles + 1` (cycles starts at 0).
    -- See docs/dst-api.md, "World state".
    if world ~= nil and world.state ~= nil and world.state.cycles ~= nil then
        return world.state.cycles + 1
    end
    return 1
end

function Objectives.GetLabel(objective)
    if objective.label ~= nil then
        return objective.label
    end

    local objective_type = objective.type
    if objective_type == "survive" then
        return string.format(DEFAULT_LABELS.survive, tonumber(objective.day) or 1)
    end

    local pattern = DEFAULT_LABELS[objective_type]
    if pattern == nil then
        return "Unknown objective: " .. tostring(objective_type)
    end

    return string.format(pattern, PrefabDisplayName(objective.prefab))
end

-- The pre-formatted counter shown on the right of a tracker row.
function Objectives.GetCounter(objective, progress)
    if objective.type == "survive" then
        local target = tonumber(objective.day) or 1
        return string.format("Day %d/%d", Objectives.GetCurrentDay(), target)
    end

    local target = tonumber(objective.count) or 1
    local value = math.min(tonumber(progress) or 0, target)
    return string.format("%d/%d", value, target)
end

-- The prefab whose inventory icon illustrates this objective, or nil when the
-- objective has no item icon (survive rows render text-only).
function Objectives.GetIconPrefab(objective)
    if objective.type == "collect" or objective.type == "build" or objective.type == "kill" then
        return objective.prefab
    end
    return nil
end

function Objectives.IsComplete(objective, progress)
    if objective.type == "survive" then
        return Objectives.GetCurrentDay() >= (tonumber(objective.day) or 1)
    end

    return (tonumber(progress) or 0) >= (tonumber(objective.count) or 1)
end

function Objectives.CountInInventory(inst, prefab)
    local inventory = inst.components.inventory
    if inventory == nil or prefab == nil then
        return 0
    end

    local count = 0
    inventory:ForEachItem(function(item)
        if item.prefab == prefab then
            local stackable = item.components.stackable
            count = count + (stackable ~= nil and stackable:StackSize() or 1)
        end
    end)
    return count
end

function Objectives.InitialProgress(inst, objective)
    if objective.type == "collect" then
        return Objectives.CountInInventory(inst, objective.prefab)
    end
    return 0
end

-- Returns how much progress the event adds to this objective. 0 means the
-- event is irrelevant to it.
function Objectives.GetEventIncrement(objective, event, data)
    if data == nil then
        return 0
    end

    if event == "itemget" then
        local item = data.item
        if objective.type == "collect" and item ~= nil and item.prefab == objective.prefab then
            local stackable = item.components.stackable
            return stackable ~= nil and stackable:StackSize() or 1
        end
    elseif event == "builditem" then
        if objective.type == "build" then
            local recipe_name = data.recipe ~= nil and data.recipe.name or nil
            local item_prefab = data.item ~= nil and data.item.prefab or nil
            if recipe_name == objective.prefab or item_prefab == objective.prefab then
                return 1
            end
        end
    elseif event == "killed" then
        local victim = data.victim
        if objective.type == "kill" and victim ~= nil and victim.prefab == objective.prefab then
            return 1
        end
    end

    return 0
end

return Objectives
