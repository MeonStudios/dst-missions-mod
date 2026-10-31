name = "Guided Missions"
description = "Configurable server-authoritative mission chains that guide players through a playthrough."
author = "matti"
version = "0.1.0"

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
        label = "Announce Progress",
        hover = "Announce mission starts and completions to all players.",
        options = {
            { description = "Enabled", data = true },
            { description = "Disabled", data = false },
        },
        default = true,
    },
}
