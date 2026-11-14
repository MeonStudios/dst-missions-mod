-- User-facing text authored in code rather than in mission data.
--
-- Mission and emergency text lives in missions.lua / emergencies.lua; this table
-- holds the strings the manager and the HUD render themselves. tools/gen_l10n.lua
-- walks both sources to build languages/en.lua, which is the translator template.
--
-- Translation keys are the English source strings themselves, so keep them short,
-- single-line, and free of `|`, `;`, quotes, and newlines.

local Strings = {}

-- Tracker heading above the optional objectives.
Strings.OPTIONAL = "Optional"

-- The terminal card once every mission is done.
Strings.ALL_COMPLETE_TITLE = "All Missions Complete"
Strings.ALL_COMPLETE_SUBTEXT = "You survived. For now."
Strings.ALL_COMPLETE_CHAT = "All guided missions are complete!"

-- Server chat/log composition. The player name and mission title are inserted by
-- the manager; only the server translates these (clients never see them except
-- as chat text).
Strings.MISSION_START_FMT = "%s - Mission %d: %s"
Strings.MISSION_COMPLETE_FMT = "%s completed: %s"
Strings.EMERGENCY_START_FMT = "%s - Emergency: %s"
Strings.EMERGENCY_RESOLVED_FMT = "%s - Emergency resolved: %s"

-- The only counter with a word in it. The tracker formats it client-side from
-- the numbers the server puts in row fields 7-8 (see netvars/docs).
Strings.DAY_COUNTER_FMT = "Day %d/%d"

-- Only these values are passed through string.format. `%` in other source text
-- (for example "Get back to 75% health") is literal, and the l10n tests must
-- not treat it as a placeholder.
Strings.FORMATS = {
    [Strings.MISSION_START_FMT] = true,
    [Strings.MISSION_COMPLETE_FMT] = true,
    [Strings.EMERGENCY_START_FMT] = true,
    [Strings.EMERGENCY_RESOLVED_FMT] = true,
    [Strings.DAY_COUNTER_FMT] = true,
}

return Strings
