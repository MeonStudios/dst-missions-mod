name = "Guided Missions"
description = "Information-only mission chains that guide players through a playthrough."
author = "PinkNeonDino"
version = "0.1.0"

-- Mods-menu icon. `icon_atlas` is a path from the mod root; `icon` is the
-- Element name inside that atlas (not a path — modindex.lua resolves the .tex
-- in the atlas's directory). Both files must exist or the game clears the
-- fields and falls back to a generic portrait background (scripts/modindex.lua:542).
icon_atlas = "icon/modicon.xml"
icon = "modicon.tex"

-- Don't Starve Together mod API version.
api_version = 10
priority = 0

dst_compatible = true
client_only_mod = false
all_clients_require_mod = true
server_filter_tags = { "missions", "quests", "guided" }

configuration_options = {
    {
        name = "SHOW_TRACKER",
        label = "Mission Tracker",
        hover = "Show the on-screen mission tracker for players.",
        options = {
            { description = "Enabled", data = true },
            { description = "Disabled", data = false },
        },
        default = true,
    },
    {
        name = "ANNOUNCE_MISSIONS",
        label = "Announce Completions",
        hover = "Announce mission completions to all players.",
        options = {
            { description = "Enabled", data = true },
            { description = "Disabled", data = false },
        },
        default = true,
    },
}
