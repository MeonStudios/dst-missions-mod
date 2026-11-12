-- Runtime settings shared by modmain, the server manager, and the client UI.
-- modmain.lua overwrites these values from modinfo configuration_options.
return {
    show_tracker = true,
    announce_missions = true,
    -- How often one emergency mission may trigger for a player:
    -- "always" | "session" | "server". modmain overwrites this from mod options.
    emergency_frequency = "session",
}
