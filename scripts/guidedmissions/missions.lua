-- Mission chain configuration.
--
-- Missions run in order. Each player progresses independently. Edit this file
-- to build your own guided playthrough; see CLAUDE.md for the full schema.
--
-- Objective types:
--   collect: prefab, count  -> acquire `count` of `prefab` (starting inventory counts)
--   craft:   prefab, count  -> craft `count` of `prefab` into the inventory
--   build:   prefab, count  -> build `count` of a structure `prefab` in the world
--   kill:    prefab, count  -> kill `count` of `prefab`
--   survive: day            -> reach this absolute world day
--
-- `craft` and `build` listen to different engine events: `builditem` fires for
-- products that can sit in the inventory (torch, spear); `buildstructure` fires
-- for things placed in the world (firepit, researchlab). Use the wrong type for
-- a prefab and that objective will never complete.
--
-- `label` is optional and carries no count: the tracker renders the counter
-- separately (for example "Collect logs" with "0/10" beside it). `subtext` is
-- required: one flavour line, 45 characters max, shown under the objectives.
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
        },
    },
    {
        id = "basic_tools",
        title = "Tools of the Trade",
        subtext = "Your hands weren't built for chopping trees.",
        objectives = {
            { type = "craft", prefab = "axe", count = 1, label = "Craft an axe" },
            { type = "craft", prefab = "pickaxe", count = 1, label = "Craft a pickaxe" },
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
        objectives = {
            { type = "craft", prefab = "torch", count = 1, label = "Craft a torch" },
            { type = "survive", day = 2, label = "Survive the first night" },
        },
    },
    {
        id = "eat_food",
        title = "Food for Thought",
        subtext = "What came first, the chicken or the egg?",
        objectives = {
            { type = "collect_food", foodtype = "VEGGIE", count = 5, label = "Collect veggies" },
            { type = "cook", count = 2, label = "Cook 2 items" },
        },
    },
    {
        id = "restore_health",
        title = "An Apple a Day...",
        subtext = "Things will hurt you. Learn how to fix that.",
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
            { type = "sanity", count = 15, label = "Restore sanity", icon = "brain" },
        },
    },
    {
        id = "collect_rocks",
        title = "Hitting Rock Bottom",
        subtext = "Gold will improve the mood.",
        objectives = {
            { type = "mine", count = 3, label = "Mine boulders" },
            { type = "collect", prefab = "goldnugget", count = 2, label = "Collect gold nuggets" },
        },
    },
    {
        id = "science_machine",
        title = "Stience!",
        subtext = "Time to use your questionable intelligence.",
        objectives = {
            { type = "build", prefab = "researchlab", count = 1, label = "Build a Science Machine" },
            { type = "prototype", count = 2, label = "Prototype recipes" },
        },
    },
    {
        id = "protection",
        title = "A Little Protection",
        subtext = "Running away works. Insurance is nice too.",
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
        id = "food_making",
        title = "The Kitchen Experiment",
        subtext = "Cooking: art, or just less raw meat.",
        objectives = {
            { type = "build", prefab = "cookpot", count = 1, label = "Build a Crock Pot" },
            { type = "build", prefab = "meatrack", count = 1, label = "Build a Drying Rack" },
            { type = "cookpot", count = 1, label = "Cook a meal in a Crock Pot" },
        },
    },
    {
        id = "preparing",
        title = "Preparing for the Long Haul",
        subtext = "Winter doesn't wait for you to unpack.",
        objectives = {
            { type = "collect", prefab = "log", count = 20, label = "Collect logs" },
            { type = "collect", prefab = "twigs", count = 30, label = "Collect twigs" },
            { type = "collect", prefab = "cutgrass", count = 30, label = "Collect grass" },
        },
    },
}
