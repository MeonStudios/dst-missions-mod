-- Localization harness.
--
--   lua tests/l10n_test.lua
--
-- Plain Lua 5.1. Checks the l10n module's fallback/alias behavior, the shipped
-- locale tables (coverage, duplicates, encoding, placeholders), and the width
-- budgets that keep translations inside the tracker's fixed layout. Never loaded
-- by the game.

local root = (arg[0] or "tests/l10n_test.lua"):match("^(.*)[/\\]tests[/\\][^/\\]+$")
    or "."
package.path = root .. "/scripts/?.lua;" .. package.path

local GLOBAL = _G

local L10n = require("guidedmissions/l10n")
local Strings = require("guidedmissions/strings")
local Missions = require("guidedmissions/missions")
local Emergencies = require("guidedmissions/emergencies")

local failures = 0
local checks = 0

local function Check(label, ok, detail)
    checks = checks + 1
    if not ok then
        failures = failures + 1
        print(string.format("FAIL: %s%s", label, detail and (" -- " .. detail) or ""))
    end
end

-- ------------------------------------------------------------- shipped files

local LANGS_DIR = root .. "/scripts/guidedmissions/languages/"
local SHIPPED = { "en", "es", "pt", "de", "fr", "it", "pl", "ru", "ko", "ja", "zh", "zht" }

local function ReadFile(path)
    local file = io.open(path, "rb")
    if file == nil then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

local function LineKeys(text)
    local keys = {}
    local duplicates = {}
    for line in text:gmatch("[^\n]+") do
        local key = line:match('^%s*%["(.-)"%]%s*=%s*"')
        if key ~= nil then
            if keys[key] then
                duplicates[#duplicates + 1] = key
            end
            keys[key] = true
        end
    end
    return keys, duplicates
end

local en_text = ReadFile(LANGS_DIR .. "en.lua")
Check("en.lua exists", en_text ~= nil)
en_text = en_text or ""

local en_keys = LineKeys(en_text)
local en_table = require("guidedmissions/languages/en")
Check("en.lua loads", type(en_table) == "table")

local locale_tables = { en = en_table }

for _, code in ipairs(SHIPPED) do
    local path = LANGS_DIR .. code .. ".lua"
    local text = ReadFile(path)
    Check("locale " .. code .. " exists", text ~= nil, path)
    text = text or ""

    Check("locale " .. code .. " has no BOM",
        text:sub(1, 3) ~= "\239\187\191")
    Check("locale " .. code .. " uses LF only",
        text:find("\r", 1, true) == nil)
    Check("locale " .. code .. " has no replacement characters",
        text:find("\239\191\189", 1, true) == nil)

    local keys, duplicates = LineKeys(text)
    Check("locale " .. code .. " has no duplicate keys", #duplicates == 0,
        table.concat(duplicates, ", "))
    Check("locale " .. code .. " defines keys", next(keys) ~= nil)

    for key in pairs(keys) do
        Check("locale " .. code .. " key is in en.lua", en_keys[key] == true, key)
    end
    for key in pairs(en_keys) do
        Check("locale " .. code .. " covers en key", keys[key] == true, key)
    end

    local path_module = L10n.BUILTIN_LOCALES[code]
    Check("locale " .. code .. " is registered in BUILTIN_LOCALES",
        path_module ~= nil)
    if path_module ~= nil then
        local ok, strings = pcall(require, path_module)
        Check("locale " .. code .. " loads", ok and type(strings) == "table")
        if ok and type(strings) == "table" then
            locale_tables[code] = strings
            for key, value in pairs(strings) do
                Check("locale " .. code .. " value is a non-empty string",
                    type(value) == "string" and #value > 0, tostring(key))
            end
        end
    end
end

-- Every source string in the data and code must appear in en.lua, and en.lua
-- must not contain anything else.
local source_keys = {}
local reserved_ok = true

local function AddSource(label, text)
    if text == nil then
        return
    end
    if type(text) ~= "string" or #text == 0 then
        reserved_ok = false
        Check("source text is a non-empty string (" .. label .. ")", false)
        return
    end
    if text:find("[|;\"\r\n]") ~= nil then
        reserved_ok = false
        Check("source text avoids reserved characters (" .. label .. ")", false, text)
    end
    source_keys[text] = true
end

local function AddObjectives(where, objectives)
    for i, objective in ipairs(objectives or {}) do
        AddSource(where .. " objective " .. i, objective.label)
    end
end

for i, mission in ipairs(Missions) do
    local where = "mission " .. i .. " (" .. tostring(mission.id) .. ")"
    AddSource(where .. " title", mission.title)
    AddSource(where .. " subtext", mission.subtext)
    AddSource(where .. " hint", mission.hint)
    AddObjectives(where, mission.objectives)
end

for i, entry in ipairs(Emergencies.entries or {}) do
    local where = "emergency " .. i .. " (" .. tostring(entry.id) .. ")"
    AddSource(where .. " title", entry.title)
    AddSource(where .. " subtext", entry.subtext)
    AddSource(where .. " resolved_subtext", entry.resolved_subtext)
    AddSource(where .. " hint", entry.hint)
    AddObjectives(where, entry.objectives)
end

for name, value in pairs(Strings) do
    if type(value) == "string" then
        AddSource("Strings." .. name, value)
    end
end

Check("source strings avoid reserved characters", reserved_ok)

for key in pairs(source_keys) do
    Check("en.lua covers source string", en_keys[key] == true, key)
end
for key in pairs(en_keys) do
    Check("en.lua key comes from data or strings.lua", source_keys[key] == true, key)
end
Check("en.lua has values equal to keys", (function()
    for key, value in pairs(en_table) do
        if value ~= key then
            return false, key
        end
    end
    return true
end)())

-- -------------------------------------------------------- placeholder parity

-- Returns the ordered list of conversion specifiers, treating %% as literal.
local function FormatSpecs(text)
    local specs = {}
    local i = 1
    while i <= #text do
        local char = text:sub(i, i)
        if char == "%" then
            local next_char = text:sub(i + 1, i + 1)
            if next_char == "%" then
                i = i + 2
            elseif next_char == "" then
                specs[#specs + 1] = "%"
                i = i + 1
            else
                specs[#specs + 1] = next_char
                i = i + 2
            end
        else
            i = i + 1
        end
    end
    return specs
end

for _, source in ipairs({
    Strings.MISSION_START_FMT,
    Strings.MISSION_COMPLETE_FMT,
    Strings.EMERGENCY_START_FMT,
    Strings.EMERGENCY_RESOLVED_FMT,
    Strings.DAY_COUNTER_FMT,
}) do
    Check("format string is in FORMATS", Strings.FORMATS[source] == true, source)
    local want = FormatSpecs(source)
    for code, strings in pairs(locale_tables) do
        local value = strings[source]
        if value ~= nil then
            local got = FormatSpecs(value)
            local same = #want == #got
            if same then
                for i = 1, #want do
                    if want[i] ~= got[i] then
                        same = false
                        break
                    end
                end
            end
            Check("locale " .. code .. " keeps placeholders", same, source)
        end
    end
end

-- ------------------------------------------------------------- width budgets

-- The English maxima the tracker's fixed layout is calibrated to. A key used in
-- several fields gets the strictest budget.
local budgets = {}

local function AddBudget(text, cap)
    if text == nil then
        return
    end
    if budgets[text] == nil or cap < budgets[text] then
        budgets[text] = cap
    end
end

for _, mission in ipairs(Missions) do
    AddBudget(mission.title, 27)
    AddBudget(mission.subtext, 52)
    AddBudget(mission.hint, 80)
    for _, objective in ipairs(mission.objectives or {}) do
        AddBudget(objective.label, 28)
    end
end

for _, entry in ipairs(Emergencies.entries or {}) do
    AddBudget(entry.title, 27)
    AddBudget(entry.subtext, 52)
    AddBudget(entry.resolved_subtext, 52)
    AddBudget(entry.hint, 80)
    for _, objective in ipairs(entry.objectives or {}) do
        AddBudget(objective.label, 28)
    end
end

-- The heading sits in the card's full-width band, so it is not width-critical;
-- 24 leaves room for a short phrase (Russian "По желанию" is 19 columns).
AddBudget(Strings.OPTIONAL, 24)
AddBudget(Strings.ALL_COMPLETE_TITLE, 27)
AddBudget(Strings.ALL_COMPLETE_SUBTEXT, 52)
-- Chat/log lines are not laid out on the card; this is only an anti-bloat cap.
AddBudget(Strings.ALL_COMPLETE_CHAT, 52)
AddBudget(Strings.MISSION_START_FMT, 48)
AddBudget(Strings.MISSION_COMPLETE_FMT, 48)
AddBudget(Strings.EMERGENCY_START_FMT, 48)
AddBudget(Strings.EMERGENCY_RESOLVED_FMT, 48)
-- The counter column is measured at runtime; 15 leaves room for "День" plus
-- three-digit days without squeezing the label column.
AddBudget(Strings.DAY_COUNTER_FMT, 15)

for code, strings in pairs(locale_tables) do
    for key, cap in pairs(budgets) do
        local value = strings[key]
        if value ~= nil then
            local width = L10n.DisplayWidth(value)
            Check("locale " .. code .. " fits width budget", width <= cap,
                string.format("%q is %d columns, budget %d", value, width, cap))
        end
    end
end

-- Estimator sanity: strict ASCII, accented Latin, and wide CJK.
Check("width: ascii", L10n.DisplayWidth("abc") == 3)
Check("width: accented latin", L10n.DisplayWidth("über") == 4)
Check("width: chinese glyphs", L10n.DisplayWidth("你好") == 6)
Check("width: mixed", L10n.DisplayWidth("第%d/%d天") == 11)
Check("width: cyrillic", L10n.DisplayWidth("Да") == 4)

-- ------------------------------------------------- module behavior (last: it
-- mutates the locale and registers fixture tables)

local saved_loc = GLOBAL.LOC

-- No LOC: English/source fallback, and the fallback is not cached.
GLOBAL.LOC = nil
L10n.SetLocale(nil)
Check("no LOC resolves to en", L10n.GetLocale() == "en")
Check("missing key falls back to source", L10n.L("Collect flint") == "Collect flint")
Check("empty string stays empty", L10n.L("") == "")
Check("nil becomes empty string", L10n.L(nil) == "")
Check("non-strings pass through", L10n.L(42) == 42)

-- LOC resolution uses the dot call and lowercases/aliases the code. A colon call
-- would pass the table as lang_id and resolve to "en", so the function below
-- deliberately rejects any argument.
GLOBAL.LOC = {
    GetLocaleCode = function(...)
        Check("GetLocaleCode is called without self", select("#", ...) == 0)
        return "ZHR"
    end,
}
L10n.SetLocale(nil)
Check("zhr aliases to zh", L10n.GetLocale() == "zh")
Check("translation is used", L10n.L("Optional") == "可选")
Check("mex aliases to es", (function()
    L10n.SetLocale("MEX")
    return L10n.GetLocale() == "es"
end)())

-- Workshop language packs: LOC keeps reporting "en" because the pack does not
-- change the profile language; LanguageTranslator.defaultlang names the PO it
-- loaded. That takes precedence, and its codes normalise.
GLOBAL.LOC = { GetLocaleCode = function() return "en" end }
GLOBAL.LanguageTranslator = { defaultlang = "fr" }
L10n.SetLocale(nil)
Check("language pack locale wins over en LOC", L10n.GetLocale() == "fr")
Check("language pack translation is used", L10n.L("Optional") == "Facultatif")

GLOBAL.LanguageTranslator.defaultlang = "pt-br"
L10n.SetLocale(nil)
Check("language pack codes normalise", L10n.GetLocale() == "pt")

GLOBAL.LanguageTranslator.defaultlang = "cs"
L10n.SetLocale(nil)
Check("unshipped language pack falls back to LOC", L10n.GetLocale() == "en")

GLOBAL.LanguageTranslator = nil

-- Missing locale: falls back to English, then to the source.
L10n.SetLocale("tr")
Check("unshipped locale falls back", L10n.L("Optional") == "Optional")

-- Lfmt formats the translation, and falls back to the source format when a
-- translation has broken placeholders.
L10n.SetLocale("de")
Check("Lfmt translates and formats", L10n.Lfmt(Strings.DAY_COUNTER_FMT, 1, 3) == "Tag 1/3")

L10n.RegisterLocale("xx", {
    [Strings.DAY_COUNTER_FMT] = "Tag %d %d %d %s",
}, 10)
L10n.SetLocale("xx")
Check("Lfmt survives a broken translation",
    L10n.Lfmt(Strings.DAY_COUNTER_FMT, 1, 3) == "Day 1/3")

L10n.SetLocale(nil)
GLOBAL.LOC = saved_loc

print(string.format("%d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end
