-- Mission chain configuration.
--
-- Missions run in order. Each player progresses independently. Edit this file
-- to build your own guided playthrough; see docs/objectives.md for the full schema.
--
-- Objective types (full reference: docs/objectives.md):
--   collect:      prefab, count              -> hold `count` of `prefab` (peak holdings)
--   craft:        prefab, count              -> craft `count` inventory items
--   build:        prefab, count              -> place `count` structures
--   kill:         prefab, count              -> kill `count` of `prefab`
--   trap_catch:   count, prefab?             -> check `count` sprung traps with a catch
--   survive:      day                        -> reach this absolute world day
--   chop:         count                      -> fell `count` trees
--   mine:         count                      -> finish mining `count` nodes
--   eat:          prefab, count              -> eat `count` of `prefab`
--   heal:         count                      -> restore `count` health points
--   sanity:       count                      -> restore `count` sanity points
--   pick:         prefab, count              -> pick `count` plants
--   collect_food: count, foodtype?,          -> hold `count` edible items
--                 secondaryfoodtype?
--   cook:         count, prefab?             -> cook `count` items on a fire
--   cookpot:      count, prefab?             -> start `count` Crock Pot dishes
--   prototype:    count, prefab?             -> learn `count` new recipes (prefab = recipe id)
--   `label` is required on every objective; `icon` only where the type lists it.
--
-- `craft` and `build` listen to different engine events: `builditem` fires for
-- products that can sit in the inventory (torch, spear); `buildstructure` fires
-- for things placed in the world (firepit, researchlab). Use the wrong type for
-- a prefab and that objective will never complete.
--
-- `label` is required and carries no count: the tracker renders the counter
-- separately (for example "Collect logs" with "0/10" beside it). `title` and
-- `subtext` are required too: `subtext` is one flavour line, 45 characters max,
-- shown under the objectives. `hint` is optional: a sentence or two shown as a
-- hover tooltip behind the "?" button; the HUD wraps it and caps it at 4 lines.
--
-- Any objective may set `optional = true`. Optional objectives are tracked like
-- the rest but never gate completion. The card groups them below the required
-- objectives under an "Optional" heading and dims them. Each mission needs at
-- least one required objective.
--
-- Missions are informational only: completing one gives no items or other
-- in-game benefit.

return {
    {
        id = "basic_supplies",
        title = "Basic Supplies",
        subtext = "All great stories start somewhere.",
        objectives = {
            { type = "collect", prefab = "flint", count = 3, label = "Collect flint" },
            { type = "collect", prefab = "twigs", count = 10, label = "Collect twigs" },
            { type = "collect", prefab = "cutgrass", count = 10, label = "Collect grass" },
            { type = "pick", prefab = "flower", count = 1, label = "Pick a flower", optional = true },
        },
    },
    {
        id = "basic_tools",
        title = "Tools of the Trade",
        subtext = "Your hands weren't built for chopping trees.",
        hint = "Use the crafting menu on the left.",
        objectives = {
            { type = "craft", prefab = "pickaxe", count = 1, label = "Craft a pickaxe" },
            { type = "craft", prefab = "axe", count = 1, label = "Craft an axe" },
        },
    },
    {
        id = "gather_wood",
        title = "Wood you Believe It?",
        subtext = "Trees are everywhere. Might as well use them.",
        objectives = {
            { type = "chop", count = 3, label = "Chop down trees" },
            { type = "collect", prefab = "log", count = 10, label = "Collect logs" },
        },
    },
    {
        id = "first_night",
        title = "Let There Be Light",
        subtext = "The dark is not your friend. Probably.",
        hint = "One torch does not last the whole night.",
        objectives = {
            { type = "craft", prefab = "torch", count = 1, label = "Craft a torch" },
            { type = "build", prefab = "campfire", count = 1, label = "Build a campfire" },
            { type = "survive", day = 2, label = "Survive the first night" },
        },
    },
    {
        id = "eat_food",
        title = "Food for Thought",
        subtext = "Veggies: now with 100% more fire.",
        hint = "Berries, carrots and mushrooms count as veggies.",
        objectives = {
            { type = "collect_food", foodtype = "VEGGIE", count = 5, label = "Collect veggies" },
            { type = "cook", count = 2, label = "Cook items" },
        },
    },
    {
        id = "restore_health",
        title = "An Apple a Day...",
        subtext = "Things will hurt you. Learn how to fix that.",
        hint = "Kill butterflies by standing on them and use the force attack keybind (Ctrl + F)",
        objectives = {
            { type = "eat", prefab = "butterflywings", count = 1, label = "Eat a butterfly wing" },
            { type = "heal", count = 10, label = "Restore at least 10 health" },
        },
    },
    {
        id = "restore_sanity",
        title = "Keeping Your Sanity",
        subtext = "It's strange enough. Don't make it worse.",
        objectives = {
            { type = "pick", prefab = "flower", count = 3, label = "Pick flowers" },
            { type = "sanity", count = 15, label = "Restore sanity" },
        },
    },
    {
        id = "collect_rocks",
        title = "Rock Solid Plan",
        subtext = "Hit things until they become useful.",
        hint = "Boulders with gold veins drop gold nuggets, found in rocky biomes",
        objectives = {
            { type = "mine", count = 3, label = "Mine boulders" },
            { type = "collect", prefab = "goldnugget", count = 1, label = "Collect a gold nugget" },
        },
    },
    {
        id = "science_machine",
        title = "Stience!",
        subtext = "Time to use your questionable intelligence.",
        hint = "Crafting a new recipe prototypes it and restores 15 sanity.",
        objectives = {
            { type = "build", prefab = "researchlab", count = 1, label = "Build a Science Machine" },
            { type = "prototype", count = 2, label = "Prototype recipes" },
        },
    },
    {
        id = "protection",
        title = "A Little Protection",
        subtext = "Running away works. Insurance is nice too.",
        hint = "Armor reduces the damage taken.",
        objectives = {
            { type = "craft", prefab = "armorwood", count = 1, label = "Craft a Log Suit" },
            { type = "craft", prefab = "spear", count = 1, label = "Craft a Spear" },
        },
    },
    {
        id = "build_camp",
        title = "Home Is Where the Fire Is",
        subtext = "Wandering's fun, but that junk needs a home.",
        objectives = {
            { type = "build", prefab = "firepit", count = 1, label = "Build a Fire Pit" },
            { type = "build", prefab = "treasurechest", count = 1, label = "Build a Chest" },
        },
    },
    {
        id = "backpack",
        title = "Carry On",
        subtext = "Room for everything but your problems.",
        objectives = {
            { type = "craft", prefab = "backpack", count = 1, label = "Craft a Backpack" },
        },
    },
    {
        id = "food_build",
        title = "The Kitchen Experiment",
        subtext = "A pot, a rack, and questionable recipes.",
        hint = "Both need charcoal: burn a tree, then chop the burnt remains.",
        objectives = {
            { type = "build", prefab = "cookpot", count = 1, label = "Build a Crock Pot" },
            { type = "build", prefab = "meatrack", count = 1, label = "Build a Drying Rack" },
            { type = "cookpot", count = 1, label = "Cook a meal in a Crock Pot" },
        },
    },
    {
        id = "find_meat",
        title = "Where's the Beef?",
        subtext = "Something out there must be edible.",
        hint = "Set traps, lure moleworms with flint, or hunt creatures.",
        objectives = {
            { type = "collect_food", foodtype = "MEAT", count = 2, label = "Collect meat" },
            { type = "trap_catch", count = 1, label = "Catch something in a trap", optional = true },
        },
    },
    {
        id = "make_meatballs",
        title = "Juicy Meatballs",
        subtext = "Mystery meat, now in convenient sphere form.",
        hint = "One meat plus three fillers (berries, carrots, mushrooms) makes meatballs.",
        objectives = {
            { type = "cookpot", prefab = "meatballs", count = 1, label = "Cook meatballs" },
        },
    },
    {
        id = "green_thumb",
        title = "Green Thumb",
        subtext = "Dirt, seeds, patience. Mostly patience.",
        hint = "Gather seeds by chasing away birds.",
        objectives = {
            { type = "craft", prefab = "farm_plow_item", count = 1, label = "Craft a Garden Digamajig" },
            { type = "craft", prefab = "farm_hoe", count = 1, label = "Craft a Garden Hoe" },
            { type = "plant", count = 4, label = "Plant seeds" },
        },
    },
    {
        id = "level_up",
        title = "Science 2.0",
        subtext = "The first machine was just a warm-up.",
        objectives = {
            { type = "build", prefab = "researchlab2", count = 1, label = "Build an Alchemy Engine" },
            { type = "prototype", count = 1, label = "Prototype a recipe" },
        },
    },
    {
        id = "warm_thoughts",
        title = "Warm Thoughts",
        subtext = "Hot rocks: the best winter pocket warmers.",
        hint = "Heat a Thermal Stone by a fire to keep you warm during winter.",
        objectives = {
            { type = "craft", prefab = "heatrock", count = 1, label = "Craft a Thermal Stone" },
            { type = "collect", prefab = "smallmeat_dried", count = 2, label = "Dry meat into jerky"},
        },
    },
    {
        id = "preparing",
        title = "Preparing for the Long Haul",
        subtext = "Winter doesn't wait for you to unpack.",
        hint = "Winter slows regrowth: stockpile logs, grass and twigs before it arrives.",
        objectives = {
            { type = "collect", prefab = "log", count = 20, label = "Collect logs" },
            { type = "collect", prefab = "twigs", count = 30, label = "Collect twigs" },
            { type = "collect", prefab = "cutgrass", count = 30, label = "Collect grass" },
        },
    },
}
