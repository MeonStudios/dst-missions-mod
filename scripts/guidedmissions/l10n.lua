-- Per-client localization.
--
-- The server writes the authored SOURCE text (English) into the tracker netvars;
-- each client translates it at render time with its own game locale. The server
-- translates only its own chat/log lines. DST has no automatic mod-translation
-- loader, and LanguageTranslator:LoadPOFile would replace the global per-language
-- table (breaking other mods), so this module keeps its own small tables.
--
-- Source strings are the translation keys. A missing table, missing key, or
-- non-string value always falls back to the source text, so a bad translation can
-- never blank the HUD or crash the mod.
--
-- Locale files live at scripts/guidedmissions/languages/<code>.lua and are loaded
-- lazily. This module runs in the normal global env (require()d modules do), so
-- pcall/require are available; modmain.lua must never load a locale file itself.

local GLOBAL = _G

local L10n = {}

L10n.FALLBACK_LOCALE = "en"

-- Shipped tables. Adding a language means adding its file and one entry here.
-- DST's locale codes: pt is Brazilian Portuguese, zh is Simplified Chinese,
-- zht is Traditional, zhr is the WeGame (Rail) client. `ja` is shipped but
-- dormant: DST's loc.lua has the Japanese entry commented out, so no client
-- resolves to it yet (L10n.SetLocale/RegisterLocale can still reach it).
L10n.BUILTIN_LOCALES = {
    en = "guidedmissions/languages/en",
    es = "guidedmissions/languages/es",
    pt = "guidedmissions/languages/pt",
    de = "guidedmissions/languages/de",
    fr = "guidedmissions/languages/fr",
    it = "guidedmissions/languages/it",
    pl = "guidedmissions/languages/pl",
    ru = "guidedmissions/languages/ru",
    ko = "guidedmissions/languages/ko",
    ja = "guidedmissions/languages/ja",
    zh = "guidedmissions/languages/zh",
    zht = "guidedmissions/languages/zht",
}

-- Locale codes that share another table. The last group covers the codes that
-- Workshop language-pack mods pass to LoadPOFile, which are not always DST's
-- own codes (the community Brazilian pack uses "br", for example).
L10n.ALIASES = {
    zhr = "zh", -- WeGame uses the same Simplified text
    mex = "es", -- Latin American Spanish shares the neutral Spanish table
    br = "pt",
    ["pt-br"] = "pt",
    ["pt_br"] = "pt",
    ["es-mx"] = "es",
    ["es_la"] = "es",
    ["zh-cn"] = "zh",
    ["zh_cn"] = "zh",
    ["zh-hans"] = "zh",
    ["zh-tw"] = "zht",
    ["zh_tw"] = "zht",
    ["zh-hant"] = "zht",
    ["ja-jp"] = "ja",
    ["ko-kr"] = "ko",
}

local override_locale = nil
local resolved_locale = nil
local builtin_loaded = {}
local next_order = 0

-- layers[code] = { { priority, order, strings }, ... }
local layers = {}
-- merged[code] = flat key -> value table, rebuilt when a layer is added
local merged = {}

local function NormaliseLocale(code)
    if type(code) ~= "string" then
        return nil
    end
    code = code:lower()
    return L10n.ALIASES[code] or code
end

local function AddLayer(code, strings, priority)
    code = NormaliseLocale(code)
    if code == nil or type(strings) ~= "table" then
        return
    end

    local list = layers[code]
    if list == nil then
        list = {}
        layers[code] = list
    end

    next_order = next_order + 1
    list[#list + 1] = {
        priority = tonumber(priority) or 0,
        order = next_order,
        strings = strings,
    }
    merged[code] = nil
end

local function EnsureBuiltin(code)
    if builtin_loaded[code] then
        return
    end
    builtin_loaded[code] = true

    local path = L10n.BUILTIN_LOCALES[code]
    if path == nil then
        return
    end

    -- A missing or syntactically broken locale file is an empty layer; the
    -- lookup then falls through to English and finally to the source string.
    local ok, strings = pcall(require, path)
    if ok and type(strings) == "table" then
        AddLayer(code, strings, 0)
    end
end

local function MergeLocale(code)
    local cached = merged[code]
    if cached ~= nil then
        return cached
    end

    EnsureBuiltin(code)

    local sorted = {}
    for i, layer in ipairs(layers[code] or {}) do
        sorted[i] = layer
    end
    -- Ascending priority, then registration order: a later registration wins a
    -- tie, so a pack can override core strings without knowing load order.
    table.sort(sorted, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.order < b.order
    end)

    local flat = {}
    for _, layer in ipairs(sorted) do
        for key, value in pairs(layer.strings) do
            if type(key) == "string" and type(value) == "string" then
                flat[key] = value
            end
        end
    end

    merged[code] = flat
    return flat
end

-- Language-pack locale. DST's Steam menu only offers English plus the
-- `in_steam_menu` locales (Simplified and Traditional Chinese); every other
-- language is a Workshop language-pack mod. Those mods call
-- LanguageTranslator:LoadPOFile(path, code), which stores the PO under `code`
-- and sets defaultlang -- but does not touch LOC/Profile:GetLanguageID(). So
-- for a French or German client LOC still says "en" and defaultlang is the only
-- signal. The post-mod TranslateStringTable(STRINGS) pass applies defaultlang,
-- so it is also the effective UI language. Only trust codes we ship.
local function TranslatorLocale()
    local translator = GLOBAL.LanguageTranslator
    if type(translator) ~= "table" then
        return nil
    end

    local code = NormaliseLocale(translator.defaultlang)
    if code ~= nil and L10n.BUILTIN_LOCALES[code] ~= nil then
        return code
    end
    return nil
end

-- The current locale, normalised and aliased. Cached once LOC exists; tests and
-- tooling can force a value with SetLocale.
function L10n.GetLocale()
    if override_locale ~= nil then
        return override_locale
    end
    if resolved_locale ~= nil then
        return resolved_locale
    end

    local pack_locale = TranslatorLocale()
    if pack_locale ~= nil then
        resolved_locale = pack_locale
        return pack_locale
    end

    local loc = GLOBAL.LOC
    if type(loc) == "table" and type(loc.GetLocaleCode) == "function" then
        -- Dot call: GetLocaleCode has no `self`, and a colon call passes the
        -- table as lang_id and silently resolves to "en".
        local ok, code = pcall(loc.GetLocaleCode)
        if ok then
            resolved_locale = NormaliseLocale(code) or L10n.FALLBACK_LOCALE
            return resolved_locale
        end
    end

    -- LOC is absent in tests, tooling, and very early boot. Do not cache, so a
    -- later call can still resolve the real locale.
    return L10n.FALLBACK_LOCALE
end

-- Test/tool override. nil clears both the override and the resolved cache.
function L10n.SetLocale(code)
    if code == nil then
        override_locale = nil
        resolved_locale = nil
        return
    end
    override_locale = NormaliseLocale(code) or tostring(code):lower()
end

-- Future mission-pack seam. Higher priority wins per key; at equal priority the
-- later registration wins. Core tables are priority 0.
function L10n.RegisterLocale(code, strings, priority)
    AddLayer(code, strings, priority)
end

function L10n.HasTranslation(source, code)
    code = NormaliseLocale(code) or L10n.FALLBACK_LOCALE
    local value = MergeLocale(code)[source]
    return type(value) == "string" and value ~= ""
end

-- Translate one source string. Returns "" for nil/empty, passes non-strings
-- through untouched, and falls back per key.
function L10n.L(source)
    if source == nil then
        return ""
    end
    if type(source) ~= "string" then
        return source
    end
    if source == "" then
        return ""
    end

    local code = L10n.GetLocale()
    local value = MergeLocale(code)[source]
    if type(value) == "string" and value ~= "" then
        return value
    end

    if code ~= L10n.FALLBACK_LOCALE then
        value = MergeLocale(L10n.FALLBACK_LOCALE)[source]
        if type(value) == "string" and value ~= "" then
            return value
        end
    end

    return source
end

-- Translate then format. A translation with broken placeholders falls back to
-- formatting the source rather than crashing the HUD or the server.
function L10n.Lfmt(source, ...)
    local translated = L10n.L(source)

    local ok, result = pcall(string.format, translated, ...)
    if ok then
        return result
    end

    ok, result = pcall(string.format, source, ...)
    if ok then
        return result
    end

    return translated
end

-- ------------------------------------------------------------ width estimate
-- Used by tests to keep translations inside the tracker's fixed layout. Lua 5.1
-- has no utf8 library, so decode UTF-8 by hand.
--
-- Weights are calibrated from the game's BMFonts. The Latin UI fonts are
-- condensed, so glyphs that fall through to DST's fallback outline font are much
-- wider than an average Latin glyph at the same size:
--   Latin (in the primary font)         1
--   Cyrillic / Greek (fallback)         2   (~1.8-2.1x)
--   CJK      (fallback full)            3   (~2.8-2.9x)
-- See fonts.lua DEFAULT_FALLBACK_TABLE_OUTLINE and docs/dst-api.md.

local ZERO_WIDTH_RANGES = {
    { 0x0300, 0x036F }, -- combining diacritics
    { 0x200B, 0x200F }, -- zero-width space/joiners
    { 0xFE00, 0xFE0F }, -- variation selectors
}

local MEDIUM_RANGES = {
    { 0x0370, 0x03FF }, -- Greek
    { 0x0400, 0x052F }, -- Cyrillic and Cyrillic Supplement
}

local WIDE_RANGES = {
    { 0x1100, 0x115F },
    { 0x2E80, 0x303E },
    { 0x3041, 0x33FF },
    { 0x3400, 0x4DBF },
    { 0x4E00, 0x9FFF },
    { 0xA000, 0xA4CF },
    { 0xAC00, 0xD7A3 },
    { 0xF900, 0xFAFF },
    { 0xFE10, 0xFE19 },
    { 0xFE30, 0xFE6F },
    { 0xFF00, 0xFF60 },
    { 0xFFE0, 0xFFE6 },
    { 0x20000, 0x3FFFD },
}

local function InRanges(codepoint, ranges)
    for _, range in ipairs(ranges) do
        if codepoint >= range[1] and codepoint <= range[2] then
            return true
        end
    end
    return false
end

local function DecodeUtf8(text, i)
    local b = string.byte(text, i)
    if b == nil then
        return nil, i
    end
    if b < 0x80 then
        return b, i + 1
    end

    local function cont(j)
        local c = string.byte(text, j)
        if c == nil or c < 0x80 or c > 0xBF then
            return nil
        end
        return c - 0x80
    end

    if b >= 0xC2 and b <= 0xDF then
        local c1 = cont(i + 1)
        if c1 == nil then
            return 0xFFFD, i + 1
        end
        return (b - 0xC0) * 0x40 + c1, i + 2
    elseif b >= 0xE0 and b <= 0xEF then
        local c1, c2 = cont(i + 1), cont(i + 2)
        if c1 == nil or c2 == nil then
            return 0xFFFD, i + 1
        end
        return (b - 0xE0) * 0x1000 + c1 * 0x40 + c2, i + 3
    elseif b >= 0xF0 and b <= 0xF4 then
        local c1, c2, c3 = cont(i + 1), cont(i + 2), cont(i + 3)
        if c1 == nil or c2 == nil or c3 == nil then
            return 0xFFFD, i + 1
        end
        return (b - 0xF0) * 0x40000 + c1 * 0x1000 + c2 * 0x40 + c3, i + 4
    end

    return 0xFFFD, i + 1
end

-- Weighted display width in "Latin character" columns.
function L10n.DisplayWidth(text)
    if type(text) ~= "string" then
        return 0
    end

    local width = 0
    local i = 1
    while i <= #text do
        local codepoint, next_i = DecodeUtf8(text, i)
        if codepoint == nil then
            break
        end

        if InRanges(codepoint, WIDE_RANGES) then
            width = width + 3
        elseif InRanges(codepoint, MEDIUM_RANGES) then
            width = width + 2
        elseif not InRanges(codepoint, ZERO_WIDTH_RANGES) then
            width = width + 1
        end

        i = next_i
    end
    return width
end

return L10n
