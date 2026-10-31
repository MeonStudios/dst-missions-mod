-- Mission chain configuration.
--
-- Missions run in order. Each player progresses independently. Edit this file
-- to build your own guided playthrough; see CLAUDE.md for the full schema.
--
-- Objective types:
--   collect: prefab, count  -> acquire `count` of `prefab` (starting inventory counts)
--   build:   prefab, count  -> build `count` of `prefab`
--   kill:    prefab, count  -> kill `count` of `prefab`
--   survive: day            -> reach this absolute world day
--
-- `label` is optional. Missions are informational only: completing one gives
-- no items or other in-game benefit.

return {
    {
        id = "gather_wood",
        title = "Gather Wood",
        objectives = {
            { type = "collect", prefab = "log", count = 10, label = "Collect 10 logs" },
        },
    },
    {
        id = "first_light",
        title = "Light the Night",
        objectives = {
            { type = "build", prefab = "torch", count = 1, label = "Craft a torch" },
        },
    },
    {
        id = "see_the_dawn",
        title = "See the Dawn",
        objectives = {
            { type = "survive", day = 2, label = "Survive until day 2" },
        },
    },
    {
        id = "basic_supplies",
        title = "Basic Supplies",
        objectives = {
            { type = "collect", prefab = "flint", count = 3, label = "Collect 3 flint" },
            { type = "collect", prefab = "twigs", count = 2, label = "Collect 2 twigs" },
        },
    },
    {
        id = "proper_camp",
        title = "A Proper Camp",
        objectives = {
            { type = "build", prefab = "firepit", count = 1, label = "Build a fire pit" },
        },
    },
    {
        id = "clear_the_nest",
        title = "Clear the Nest",
        objectives = {
            { type = "kill", prefab = "spider", count = 3, label = "Kill 3 spiders" },
        },
    },
    {
        id = "prospector",
        title = "Prospector",
        objectives = {
            { type = "collect", prefab = "goldnugget", count = 3, label = "Collect 3 gold nuggets" },
        },
    },
    {
        id = "science",
        title = "Science!",
        objectives = {
            { type = "build", prefab = "researchlab", count = 1, label = "Build a Science Machine" },
        },
    },
}
