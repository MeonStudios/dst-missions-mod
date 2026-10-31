-- Netvar plumbing shared by the server manager and the client tracker.
--
-- These declarations MUST run on both the server and every client, with the
-- same names and in the same order. modmain.lua calls Attach() for every
-- player on both sides.

-- Files loaded via require() run in the raw global environment, so `GLOBAL`
-- (which DST only injects into the modmain environment) is undefined here.
-- `_G` is the same table that modmain's `GLOBAL` points at.
local GLOBAL = _G

local Netvars = {}

Netvars.DIRTY_EVENT = "guidedmissionsdirty"

-- Fixed order: netvars must be declared in the same order on server and client.
local FIELDS = { "title", "subtext", "rows", "state" }

local FIELD_VARS = {
    title = "_guidedmissions_title",
    subtext = "_guidedmissions_subtext",
    rows = "_guidedmissions_rows",
    state = "_guidedmissions_state",
}

local FIELD_NAMES = {
    title = "guidedmissions.title",
    subtext = "guidedmissions.subtext",
    rows = "guidedmissions.rows",
    state = "guidedmissions.state",
}

function Netvars.Attach(inst)
    if inst[FIELD_VARS.title] ~= nil then
        return
    end

    for _, field in ipairs(FIELDS) do
        inst[FIELD_VARS[field]] = GLOBAL.net_string(inst.GUID, FIELD_NAMES[field], Netvars.DIRTY_EVENT)
    end
end

function Netvars.Read(inst)
    local state = {}
    for _, field in ipairs(FIELDS) do
        local netvar = inst[FIELD_VARS[field]]
        state[field] = netvar ~= nil and netvar:value() or ""
    end
    return state
end

function Netvars.Write(inst, state)
    for _, field in ipairs(FIELDS) do
        local netvar = inst[FIELD_VARS[field]]
        if netvar ~= nil then
            netvar:set(state[field] or "")
        end
    end
end

return Netvars
