-- See netvars.lua: require()d modules cannot see modmain's `GLOBAL` binding.
local GLOBAL = _G

local Conditions = require("guidedmissions/conditions")
local Strings = require("guidedmissions/strings")

local Objectives = {}

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

-- `label` is required mission data, authored per objective. Labels never carry
-- a count: the tracker renders the counter separately.
function Objectives.GetLabel(objective)
    return objective.label
end

-- Optional objectives are tracked and rendered like any other, but never block
-- mission completion (`optional = true` in mission data).
function Objectives.IsOptional(objective)
    return objective.optional == true
end

-- The pre-formatted counter shown on the right of a tracker row. This is SOURCE
-- text: the client formats the day counter in its own language from the numbers
-- GetCounterMeta supplies (see FormatRows in manager.lua).
function Objectives.GetCounter(objective, progress)
    if objective.type == "survive" then
        local target = tonumber(objective.day) or 1
        return string.format(Strings.DAY_COUNTER_FMT, Objectives.GetCurrentDay(), target)
    end

    if objective.type == "reach_stat" then
        -- A live percentage, not a count: "40/75%". Only the target carries the
        -- unit, matching the "current/target" style of every other counter. The
        -- tracker replaces the counter with a checkmark once the threshold is
        -- met.
        local _, target = Conditions.ParseThreshold(objective.threshold)
        if target == nil then
            return ""
        end
        local value = math.floor(tonumber(progress) or 0)
        return string.format("%d/%d%%", value, target)
    end

    local target = tonumber(objective.count) or 1
    -- Heal progress is fractional when health comes back over time; show whole
    -- points. `%d` would truncate anyway, but this makes it explicit.
    local value = math.floor(math.min(tonumber(progress) or 0, target))
    return string.format("%d/%d", value, target)
end

-- Extra row fields for counters the client must format itself, because the
-- counter contains a translated word. Returns kind, current, target; kind == ""
-- means the pre-formatted counter is language-neutral and is rendered as-is.
-- The day counter is the only one today ("Day %d/%d"): ratios and percentages
-- are pure numbers in every language.
function Objectives.GetCounterMeta(objective, progress)
    if objective.type == "survive" then
        return "day", Objectives.GetCurrentDay(), tonumber(objective.day) or 1
    end
    return "", nil, nil
end

-- The prefab whose inventory icon illustrates this objective, or nil when the
-- objective has no item icon (survive rows render text-only).
function Objectives.GetIconPrefab(objective)
    if objective.type == "reach_stat" then
        -- The same HUD badge glyphs the heal/sanity rows use, chosen by stat.
        return objective.icon
            or (objective.stat == "health" and "heart" or "brain")
    end
    if objective.type == "sleep" then
        -- Tents and bedrolls are world/inventory objects without a useful row
        -- icon here; the row is deliberately text-only (`icon` is ignored).
        return nil
    end
    if objective.type == "chop" then
        -- A chop objective has no prefab of its own: trees are matched by tag,
        -- not id. The default shows the axe that does the chopping; `icon` lets
        -- a mission override it.
        return objective.icon or "axe"
    end
    if objective.type == "mine" then
        -- Likewise for mining: default to the pickaxe, with `icon` to override.
        return objective.icon or "pickaxe"
    end
    if objective.type == "heal" then
        -- The HUD health badge's heart glyph, like `brain` for sanity; `icon`
        -- overrides it (for example with `healingsalve`).
        return objective.icon or "heart"
    end
    if objective.type == "sanity" then
        -- No inventory item represents "sanity", so the row defaults to the
        -- HUD sanity-brain art (`brain`); `icon` overrides it.
        return objective.icon or "brain"
    end
    if objective.type == "pick" then
        -- Plants are not inventory items, so most have no icon. The tracker has
        -- art for the vanilla flower; `icon` lets any other plant point at an
        -- item icon instead (e.g. berries for a berry bush).
        return objective.icon or objective.prefab
    end
    if objective.type == "plant" then
        -- The planted crop is a world entity with no inventory icon, but the
        -- seed the player held has one (`carrot_seeds`, `pumpkin_seeds`, ...).
        -- An unfiltered objective shows the generic seed art; `icon` overrides.
        return objective.icon or objective.prefab or "seeds"
    end
    if objective.type == "collect_food" then
        -- "Any food" has no single icon; `icon` can point at one.
        return objective.icon
    end
    if objective.type == "cook" or objective.type == "cookpot" then
        -- The icon is the cooked product or dish itself, so `prefab` doubles
        -- as the art id. There is no separate `icon` field; an unfiltered
        -- objective has no single item to show and renders text-only.
        return objective.prefab
    end
    if objective.type == "prototype" then
        -- A targeted recipe shows its product's icon (recipe id = product
        -- prefab id); "any recipe" falls back to the blueprint item. An
        -- explicit `icon` wins over both.
        return objective.icon or objective.prefab or "blueprint"
    end
    if objective.type == "trap_catch" then
        -- The trapped creature's icon when filtered (`rabbit`, `spider`,
        -- `frog`, ...); an unfiltered objective falls back to the trap item.
        return objective.prefab or "trap"
    end
    if objective.type == "fertilize" then
        -- Like `pick`/`plant`: the fertilized plant is a world entity, so a
        -- filtered row (`berrybush`, `grass`) usually has no inventory art and
        -- draws nothing unless `icon` points at an item (e.g. `berries`). An
        -- unfiltered row shows the rot item, the most common fertilizer.
        return objective.icon or objective.prefab or "rot"
    end

    if objective.type == "collect" or objective.type == "craft"
        or objective.type == "build" or objective.type == "kill"
        or objective.type == "eat" then
        return objective.prefab
    end
    return nil
end

function Objectives.IsComplete(objective, progress)
    if objective.type == "survive" then
        return Objectives.GetCurrentDay() >= (tonumber(objective.day) or 1)
    end

    if objective.type == "reach_stat" then
        local operator, target = Conditions.ParseThreshold(objective.threshold)
        if operator == nil then
            return false
        end
        return Conditions.Matches(operator, tonumber(progress) or 0, target)
    end

    local value = tonumber(progress) or 0
    local target = tonumber(objective.count) or 1
    if objective.type == "heal" or objective.type == "sanity" then
        -- Restored points arrive in fractional deltas (overtime healing, the
        -- sanity rate); allow for float accumulation landing a hair below.
        return value + 0.0001 >= target
    end
    return value >= target
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

-- Food types are plain strings on the edible component (`FOODTYPE.VEGGIE` is
-- "VEGGIE" in constants.lua). A berry is main type VEGGIE with secondary type
-- BERRY, and both `berries` and `berries_juicy` use that pair, so
-- `secondaryfoodtype = "BERRY"` counts either berry variant. Note that
-- `foodtype = "VEGGIE"` counts carrots *and* berries *and* every other veggie.
local function MatchesFoodType(objective, edible)
    if objective.foodtype ~= nil and edible.foodtype ~= objective.foodtype then
        return false
    end
    if objective.secondaryfoodtype ~= nil
        and edible.secondaryfoodtype ~= objective.secondaryfoodtype then
        return false
    end
    return true
end

-- Any item with an edible component counts as food, cooked or raw. The optional
-- `foodtype` / `secondaryfoodtype` fields narrow it.
function Objectives.CountFoodInInventory(inst, objective)
    local inventory = inst.components.inventory
    if inventory == nil then
        return 0
    end

    local count = 0
    inventory:ForEachItem(function(item)
        local components = item.components
        local edible = components ~= nil and components.edible or nil
        if edible ~= nil and MatchesFoodType(objective, edible) then
            local stackable = components.stackable
            count = count + (stackable ~= nil and stackable:StackSize() or 1)
        end
    end)
    return count
end

-- The current stat percentage (0-100) for a `reach_stat` row, or nil for any
-- other type or a missing component. The manager refreshes these on stat events
-- and once per second, so the row follows the live value rather than an
-- accumulated one.
function Objectives.LiveProgress(inst, objective)
    if objective == nil or objective.type ~= "reach_stat" then
        return nil
    end
    local fraction = Conditions.GetStatFraction(inst, objective.stat)
    if fraction == nil then
        return nil
    end
    return fraction * 100
end

function Objectives.InitialProgress(inst, objective)
    if objective.type == "collect" then
        return Objectives.CountInInventory(inst, objective.prefab)
    end
    if objective.type == "collect_food" then
        return Objectives.CountFoodInInventory(inst, objective)
    end
    local live = Objectives.LiveProgress(inst, objective)
    if live ~= nil then
        return live
    end
    return 0
end

-- collect/collect_food progress is derived from the inventory, never accumulated from
-- events. Two verified engine behaviours make event counting unsafe:
--   * `itemget` fires only when an item lands in an *empty* slot, so pickups
--     that merge into an existing stack are invisible (stackable:Put emits
--     nothing), and
--   * `itemget` fires again from `Inventory:GiveActiveItem` every time an item
--     is clicked onto the cursor, so adding its stack size each time lets a
--     player inflate the counter just by clicking their own inventory.
-- Take the peak inventory count instead: it rises when items are acquired,
-- never falls when they are spent or dropped, and internal inventory moves do
-- not change it. The manager calls this from its inventory-event handler
-- (deferred one tick, see OnInventoryChanged), not from a periodic poll.
function Objectives.ReconcileProgress(inst, objective, progress)
    local value = tonumber(progress) or 0
    if objective.type == "collect" then
        return math.max(value, Objectives.CountInInventory(inst, objective.prefab))
    end
    if objective.type == "collect_food" then
        return math.max(value, Objectives.CountFoodInInventory(inst, objective))
    end
    -- reach_stat mirrors the live stat, so it may fall as well as rise.
    local live = Objectives.LiveProgress(inst, objective)
    if live ~= nil then
        return live
    end
    return value
end

local function MatchesRecipe(objective, data)
    local recipe_name = data.recipe ~= nil and data.recipe.name or nil
    local item_prefab = data.item ~= nil and data.item.prefab or nil
    return recipe_name == objective.prefab or item_prefab == objective.prefab
end

-- `components/workable.lua` pushes `working` on the worker *after* decrementing
-- the target's workleft, so workleft 0 means this swing felled the target. It
-- fires for every workable action (chop, mine, dig, hammer) and `actions.lua`
-- also pushes it with no target when a wet tool slips out of the hand, so the
-- target has to be inspected rather than trusted.
--
-- "Cut down a tree" means: the `tree` tag, not a stump (stumps keep `tree` and
-- switch their workable action to DIG), the CHOP action (marble/petrified trees
-- are MINE), and no work left. See docs/dst-api.md, "Player hooks and events".
local function FelledTree(target)
    if target == nil or not target:HasTag("tree") or target:HasTag("stump") then
        return false
    end

    local workable = target.components ~= nil and target.components.workable or nil
    if workable == nil then
        return false
    end

    local actions = GLOBAL.ACTIONS
    if actions ~= nil and actions.CHOP ~= nil and workable.action ~= actions.CHOP then
        return false
    end

    return (workable.workleft or 1) <= 0
end

-- Any completed MINE-action work counts, per the objective's "a mine swing is
-- good enough" rule: boulders, salt rocks, moon rocks, marble and petrified
-- trees all end with workleft 0 and action MINE.
local function MinedNode(target)
    local workable = target ~= nil and target.components ~= nil and target.components.workable or nil
    if workable == nil then
        return false
    end

    local actions = GLOBAL.ACTIONS
    if actions ~= nil and actions.MINE ~= nil and workable.action ~= actions.MINE then
        return false
    end

    return (workable.workleft or 1) <= 0
end

-- Health credited by a `healthdelta`: the requested heal, `amount`. It is a
-- heal attempt, not the amount that fit on the bar -- a +20 food eaten at
-- 148/150 credits 20, and a heal at full health (all overheal) credits its
-- amount too, since DoDelta pushes the event even when SetVal clamps the value
-- and the percentages stay equal. Damage (negative amount) and no-op deltas
-- (amount 0) count nothing. See docs/dst-api.md, "Player hooks and events".
local function HealthGained(inst, data)
    return math.max(tonumber(data.amount) or 0, 0)
end

-- Sanity credited by a `sanitydelta`: the requested delta, like health. The
-- event carries no amount (`components/sanity.lua:405`), so modmain's sanity
-- post-init records it on the component before DoDelta pushes the event (see
-- `_guidedmissions_last_delta`). Using the requested delta means a gain that
-- overflows the bar credits in full, and it sidesteps `GetPercent()` being
-- forced to 0/1 by induced insanity or lunacy.
--
-- Fallback for a `sanitydelta` with no recorded delta (the component was not
-- post-inited): the percent difference scaled by `sanity.max`, the plain field
-- behind `Sanity:SetMax`.
local function SanityGained(inst, data)
    local sanity = inst ~= nil and inst.components ~= nil and inst.components.sanity or nil

    local requested = sanity ~= nil and tonumber(sanity._guidedmissions_last_delta) or nil
    if requested ~= nil then
        return requested > 0 and requested or 0
    end

    local old_percent = tonumber(data.oldpercent) or 0
    local new_percent = tonumber(data.newpercent) or 0
    if new_percent <= old_percent then
        return 0
    end

    if sanity == nil or sanity.max == nil then
        return 0
    end

    return (new_percent - old_percent) * sanity.max
end

-- Returns how much progress the event adds to this objective. 0 means the
-- event is irrelevant to it. `inst` is the player the event fired on; the
-- sanity objective needs it to read the requested delta that modmain records on
-- the sanity component.
function Objectives.GetEventIncrement(objective, event, data, inst)
    if data == nil then
        return 0
    end

    if (event == "builditem" and objective.type == "craft")
        or (event == "buildstructure" and objective.type == "build") then
        -- `builditem` is an inventory item; `buildstructure` is something
        -- placed in the world. The two objective types are deliberately kept
        -- apart so a mission says which one it means. See docs/dst-api.md.
        if MatchesRecipe(objective, data) then
            return 1
        end
    elseif event == "killed" then
        local victim = data.victim
        if objective.type == "kill" and victim ~= nil and victim.prefab == objective.prefab then
            return 1
        end
    elseif event == "working" then
        if objective.type == "chop" and FelledTree(data.target) then
            return 1
        elseif objective.type == "mine" and MinedNode(data.target) then
            return 1
        end
    elseif event == "healthdelta" then
        if objective.type == "heal" then
            return HealthGained(inst, data)
        end
    elseif event == "sanitydelta" then
        if objective.type == "sanity" then
            return SanityGained(inst, data)
        end
    elseif event == "picksomething" then
        -- Pushed on the picker by components/pickable.lua when a pick produces
        -- loot; `object` is the picked plant. Flower picking restores sanity
        -- directly (prefabs/flower.lua:57), so counting picks is the trigger.
        if objective.type == "pick" and data.object ~= nil
            and data.object.prefab == objective.prefab then
            return 1
        end
    elseif event == "oneat" then
        -- `oneat` is pushed on the eater with the food entity (components/eater.lua).
        if objective.type == "eat" and data.food ~= nil
            and data.food.prefab == objective.prefab then
            return 1
        end
    elseif event == "guidedmissions_cookedfood" then
        -- Pushed by modmain's `cooker` post-init, because vanilla emits no
        -- player event on a successful cook. `product` is the cooked item.
        if objective.type == "cook" then
            local product = data.product
            if objective.prefab == nil
                or (product ~= nil and product.prefab == objective.prefab) then
                return 1
            end
        end
    elseif event == "guidedmissions_stewedfood" then
        -- Pushed by modmain's `stewer` post-init when a crockpot starts cooking.
        -- `product` is the dish's prefab id (a string, not an entity).
        if objective.type == "cookpot" then
            local product = data.product
            if objective.prefab == nil or product == objective.prefab then
                return 1
            end
        end
    elseif event == "guidedmissions_planted" then
        -- Pushed by modmain's `farmplantable`/`deployable` post-inits, because
        -- putting a plant in the ground emits no player event. `item` is the
        -- prefab id of the thing the player held (a string): a seed
        -- (`carrot_seeds`, `seeds`) for tilled soil, or a dug plant
        -- (`dug_berrybush`) or other plantable (`pinecone`, `acorn`) for a
        -- deploy. It is never the crop or bush that grows from it. See
        -- docs/dst-api.md, "Farming and planting".
        if objective.type == "plant" then
            local item = data.item
            if objective.prefab == nil or item == objective.prefab then
                return 1
            end
        end
    elseif event == "unlockrecipe" then
        -- Pushed by Builder:UnlockRecipe when a recipe is prototyped at a
        -- station or learned (blueprint, scanner). The data-less variant from
        -- Builder:GiveAllRecipes must not count. See docs/dst-api.md.
        if objective.type == "prototype" and data.recipe ~= nil
            and (objective.prefab == nil or data.recipe == objective.prefab) then
            return 1
        end
    elseif event == "guidedmissions_trapchecked" then
        -- Pushed by modmain's `trap` post-init when the player checks a sprung
        -- trap that holds a catch. `loot` is the trap's stored loot list: an
        -- inventory-item catch (rabbit) stores the creature itself, while
        -- lootdropper catches (spider, frog) store their drops, so a `prefab`
        -- filter matches loot ids, not necessarily the creature.
        if objective.type == "trap_catch" then
            if objective.prefab == nil then
                return 1
            end
            for _, prefab in ipairs(data.loot or {}) do
                if prefab == objective.prefab then
                    return 1
                end
            end
        end
    elseif event == "guidedmissions_slept" then
        -- Pushed by modmain's `sleepingbaguser` post-init when the player enters
        -- a tent/bedroll. `bed` is the bed entity; `prefab` filters its kind
        -- (`tent`, `siestahut`, a bedroll), and no filter accepts any bed.
        if objective.type == "sleep"
            and (objective.prefab == nil
                or (data.bed ~= nil and data.bed.prefab == objective.prefab)) then
            return 1
        end
    elseif event == "guidedmissions_fertilized" then
        -- Pushed by modmain's `pickable` post-init, because fertilizing a bush
        -- or grass tuft emits no player event. `plant` is the fertilized
        -- entity, so `prefab` matches the plant (`berrybush`, `grass`), not the
        -- fertilizer. Farm crops and old farm plots are not reported, so this
        -- only ever sees a pickable plant.
        if objective.type == "fertilize"
            and (objective.prefab == nil
                or (data.plant ~= nil and data.plant.prefab == objective.prefab)) then
            return 1
        end
    end

    return 0
end

-- The objective types this module matches. Mission data is validated against
-- this in tests/manager_test.lua: a misspelt type (`cood`, or `collect` with a
-- made-up prefab) parses fine and then silently matches no event, so the
-- objective would never complete.
Objectives.VALID_TYPES = {
    collect = true,
    craft = true,
    build = true,
    kill = true,
    survive = true,
    chop = true,
    mine = true,
    eat = true,
    heal = true,
    sanity = true,
    pick = true,
    plant = true,
    collect_food = true,
    cook = true,
    cookpot = true,
    prototype = true,
    trap_catch = true,
    sleep = true,
    fertilize = true,
    reach_stat = true,
}

return Objectives
