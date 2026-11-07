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
-- required: one flavour line, ~50 characters max, shown under the objectives.
--
-- Missions are informational only: completing one gives no items or other
-- in-game benefit.

return {
    {
        id = "basic_supplies",
        title = "Basic Supplies",
        subtext = "Rock. Stick. Civilisation, basically.",
        objectives = {
            { type = "collect", prefab = "flint", count = 3, label = "Collect flint" },
            { type = "collect", prefab = "twigs", count = 2, label = "Collect twigs" },
        },
    },
    {
        id = "gather_wood",
        title = "A Wooden Start",
        subtext = "Everything worth building starts with a log.",
        objectives = {
            { type = "collect", prefab = "log", count = 10, label = "Collect logs" },
        },
    },
    {
        id = "first_light",
        title = "Light the Night",
        subtext = "The dark is not your friend. Probably.",
        objectives = {
            { type = "craft", prefab = "torch", count = 1, label = "Craft a torch" },
        },
    },
    {
        id = "see_the_dawn",
        title = "See the Dawn",
        subtext = "Just don't stare at the fire all night.",
        objectives = {
            { type = "survive", day = 3, label = "Survive until day 3" },
        },
    },
    {
        id = "proper_camp",
        title = "A Proper Camp",
        subtext = "A hole with fire in it. Home, at last.",
        objectives = {
            { type = "build", prefab = "firepit", count = 1, label = "Build a fire pit" },
        },
    },
    {
        id = "clear_the_nest",
        title = "Clear the Nest",
        subtext = "They were here first. Doesn't matter.",
        objectives = {
            { type = "kill", prefab = "spider", count = 3, label = "Kill spiders" },
        },
    },
    {
        id = "prospector",
        title = "Prospector",
        subtext = "Shiny. Shiny is good. Shiny is very good.",
        objectives = {
            { type = "collect", prefab = "goldnugget", count = 3, label = "Collect gold nuggets" },
        },
    },
    {
        id = "science",
        title = "Science!",
        subtext = "Understand the world. One rock at a time.",
        objectives = {
            { type = "build", prefab = "researchlab", count = 1, label = "Build a Science Machine" },
        },
    },
}
