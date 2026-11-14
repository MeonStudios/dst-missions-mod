-- Runtime settings shared by modmain, the server manager, and the client UI.
-- modmain.lua overwrites these values from modinfo configuration_options.
return {
    show_tracker = true,
    announce_missions = true,
    -- Multiplayer Mode: a `shared` build row is satisfied by an equivalent
    -- structure already standing nearby (see docs/objectives.md).
    multiplayer_mode = true,
    -- How often one emergency mission may trigger for a player:
    -- "always" | "session" | "server". modmain overwrites this from mod options.
    emergency_frequency = "session",
}
