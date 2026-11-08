-- Sandbox harness for modmain.lua's console commands.
--
-- DST does not run modmain.lua in the normal global environment: mods.lua
-- `CreateEnvironment` gives it a whitelist with no `_G` fallback, and that
-- whitelist omits `tonumber`. The manager harness cannot catch a modmain that
-- calls a missing base function, so this file loads the real modmain.lua into
-- an environment with the same whitelist and exercises c_resetmissions /
-- c_setmission (server, local-console RPC, and RPC-handler paths).
--
-- Run from anywhere:
--
--   "/c/Program Files (x86)/Lua/5.1/lua.exe" tests/modmain_test.lua
--
-- It stubs the engine API; it does not verify netvar replication or console UI.

-- Resolve the repo root from this script's own path so the harness works
-- regardless of the current directory.
local script_path = arg and arg[0] or "tests/modmain_test.lua"
local tests_dir = script_path:match("^(.*)[/\\][^/\\]+$") or "."
local root = tests_dir .. "/.."
package.path = root .. "/scripts/?.lua;" .. package.path

local failures = 0

local function Check(label, cond, detail)
    if cond then
        print("PASS  " .. label)
    else
        failures = failures + 1
        print("FAIL  " .. label .. (detail ~= nil and (" -- " .. tostring(detail)) or ""))
    end
end

-- The game does not pcall console commands: an error is printed to the log and
-- the command simply fails. Report it as a FAIL here instead of aborting the
-- whole harness, so one broken command does not hide the remaining checks.
local function Run(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        Check("console command should not error", false, err)
    end
    return ok
end

-- ---- engine stubs ---------------------------------------------------------

local net = {
    is_server = true,
    is_admin = true,
    dedicated = false,
    clients = {},
}

TheNet = {
    GetIsServer = function() return net.is_server end,
    GetIsServerAdmin = function() return net.is_admin end,
    IsDedicated = function() return net.dedicated end,
    GetClientTableForUser = function(_, userid) return net.clients[userid] end,
    Announce = function() end,
}

local rpc_handlers = {}
local sent_rpcs = {}
local console_output = {}
local component_postinits = {}

local function RecordPrint(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    console_output[#console_output + 1] = table.concat(parts, " ")
end

local function ModAPI(env)
    env.GetModConfigData = function() return true end
    env.AddModRPCHandler = function(namespace, name, fn)
        rpc_handlers[namespace .. "/" .. name] = fn
    end
    env.AddPlayerPostInit = function() end
    env.AddPrefabPostInit = function() end
    env.AddComponentPostInit = function(component, fn)
        component_postinits[component] = fn
    end
    env.Asset = function(kind, path)
        return { kind = kind, path = path }
    end
    env.GetModRPC = function(namespace, name)
        return { namespace = namespace, id = name }
    end
    env.SendModRPCToServer = function(id_table, ...)
        sent_rpcs[#sent_rpcs + 1] = { id_table = id_table, args = { ... }, n = select("#", ...) }
    end
end

-- Minimal class helper: DST injects `Class` into the mod env (mods.lua does
-- not, but the mod env also gets it via the boots). modmain does not use it
-- today; provide it so adding a class there does not break this harness.
function Class(base, ctor)
    if ctor == nil then
        ctor = base
        base = nil
    end
    local cls = {}
    cls.__index = cls
    if base then
        setmetatable(cls, { __index = base })
    end
    setmetatable(cls, {
        __index = base,
        __call = function(c, ...)
            local obj = setmetatable({}, cls)
            ctor(obj, ...)
            return obj
        end,
    })
    return cls
end

-- ---- the modmain environment (mirrors mods.lua CreateEnvironment) ---------

local env = {
    -- Lua whitelist, exactly as mods.lua lists it. NOTE: no tonumber.
    pairs = pairs,
    ipairs = ipairs,
    print = RecordPrint,
    math = math,
    table = table,
    type = type,
    string = string,
    tostring = tostring,
    require = require,
    Class = Class,
    GLOBAL = _G,
    modname = "dst-mission-mod",
    MODROOT = root .. "/",
}
env.env = env
ModAPI(env)

Check("sandbox has no tonumber (faithful to the game env)", rawget(env, "tonumber") == nil)

_G.c_setmission = nil
_G.c_resetmissions = nil

local chunk = assert(loadfile(root .. "/modmain.lua"))
setfenv(chunk, env)
local ok, err = pcall(chunk)
Check("modmain loads in the sandbox", ok, err)

Check("c_setmission is a console global", type(_G.c_setmission) == "function")
Check("c_resetmissions is a console global", type(_G.c_resetmissions) == "function")

Check("flower anim asset declared",
    type(env.Assets) == "table" and env.Assets[1] ~= nil
    and env.Assets[1].path == "anim/flowers.zip")

-- ---- cooker post-init -----------------------------------------------------
-- Fire cooking has no vanilla player event; modmain wraps Cooker:CookItem to
-- report successful cooks. Drive the registered post-init directly.

local cooker_postinit = component_postinits.cooker
Check("cooker post-init registered", type(cooker_postinit) == "function")

local function NewCooker(product)
    local cooker = {}
    function cooker:CookItem()
        return product
    end
    return cooker
end

local function NewChef()
    local events = {}
    return {
        events = events,
        PushEvent = function(_, name, data)
            events[#events + 1] = { name = name, data = data }
        end,
    }
end

if type(cooker_postinit) == "function" then
    local product = { prefab = "cookedmeat", components = { edible = {} } }
    local cooker = NewCooker(product)
    cooker_postinit(cooker)
    local chef = NewChef()
    local returned = cooker:CookItem({ prefab = "meat" }, chef)
    Check("cooker wrapper returns the product unchanged", returned == product)
    Check("cooker wrapper reports cooked food",
        #chef.events == 1 and chef.events[1].name == "guidedmissions_cookedfood")
    Check("guidedmissions_cookedfood event carries the product",
        chef.events[1] ~= nil and chef.events[1].data.product == product)

    -- A failed cook (CanCook false) returns nil and must report nothing.
    local failed = NewCooker(nil)
    cooker_postinit(failed)
    local failed_chef = NewChef()
    Check("failed cook returns nil", failed:CookItem({}, failed_chef) == nil)
    Check("failed cook reports nothing", #failed_chef.events == 0)

    -- Cooking something that does not produce an edible item is not food.
    local nonfood = NewCooker({ prefab = "ash", components = {} })
    cooker_postinit(nonfood)
    local nonfood_chef = NewChef()
    nonfood:CookItem({}, nonfood_chef)
    Check("non-food cook reports nothing", #nonfood_chef.events == 0)

    -- No chef (non-player cooker use) must not error.
    local chefless = NewCooker(product)
    cooker_postinit(chefless)
    Check("nil chef is safe", chefless:CookItem({}) == product)
end

-- ---- stewer post-init -----------------------------------------------------

local stewer_postinit = component_postinits.stewer
Check("stewer post-init registered", type(stewer_postinit) == "function")

local function NewStewer()
    local stewer = { product = nil, targettime = nil, done = nil }
    function stewer:IsCooking()
        return not self.done and self.targettime ~= nil
    end
    function stewer:StartCooking()
        self.product = "meatballs"
        self.ingredient_prefabs = { "meat", "berries", "berries", "berries" }
        self.targettime = 10
        self.done = nil
    end
    return stewer
end

if type(stewer_postinit) == "function" then
    local stewer = NewStewer()
    stewer_postinit(stewer)
    local chef = NewChef()
    stewer:StartCooking(chef)
    Check("stewer wrapper reports the dish",
        #chef.events == 1 and chef.events[1].name == "guidedmissions_stewedfood")
    Check("stewed event carries the product",
        chef.events[1] ~= nil and chef.events[1].data.product == "meatballs")

    -- Already cooking: a second start must not report another dish.
    stewer:StartCooking(chef)
    Check("already-cooking start reports nothing", #chef.events == 1)

    -- A pot that does not start (no product, not cooking) must report nothing.
    local empty = { product = nil, targettime = nil, done = nil }
    function empty:IsCooking() return not self.done and self.targettime ~= nil end
    function empty:StartCooking() end
    stewer_postinit(empty)
    local empty_chef = NewChef()
    empty:StartCooking(empty_chef)
    Check("failed stewer start reports nothing", #empty_chef.events == 0)

    -- No chef (non-player trigger) must not error.
    local chefless = NewStewer()
    stewer_postinit(chefless)
    local ok = pcall(function() chefless:StartCooking(nil) end)
    Check("stewer start with nil chef is safe", ok)
end

-- ---- sanity post-init -----------------------------------------------------

local sanity_postinit = component_postinits.sanity
Check("sanity post-init registered", type(sanity_postinit) == "function")

if type(sanity_postinit) == "function" then
    local sanity = { current = 100, max = 100, pushed = {} }
    -- Stand-in for Sanity:DoDelta: clamp like vanilla and remember what the
    -- wrapper had recorded at the moment the event-equivalent runs.
    function sanity:DoDelta(delta)
        self.pushed[#self.pushed + 1] = self._guidedmissions_last_delta
        self.current = math.min(math.max(self.current + delta, 0), self.max)
    end

    sanity_postinit(sanity)
    sanity:DoDelta(5)
    Check("sanity wrapper records the requested delta", sanity.pushed[1] == 5)
    Check("sanity wrapper does not change the clamped value", sanity.current == 100)

    sanity:DoDelta(-30)
    Check("sanity wrapper records losses too", sanity.pushed[2] == -30)
    Check("sanity wrapper leaves DoDelta behaviour intact", sanity.current == 70)
end

-- ---- fake players ---------------------------------------------------------

local jumps = {}
local function NewPlayer(userid)
    local manager = {}
    -- Mirrors GuidedMissionManager:JumpTo's contract: out-of-range indices
    -- change nothing and return false.
    function manager:JumpTo(index)
        if index == nil or index < 1 or index > 99 then
            return false
        end
        jumps[#jumps + 1] = index
        return true
    end
    return {
        userid = userid,
        components = { guidedmissionmanager = manager },
    }
end

local function LastJump()
    return jumps[#jumps]
end

local function OutputContains(text)
    for _, line in ipairs(console_output) do
        if line:find(text, 1, true) ~= nil then
            return true
        end
    end
    return false
end

-- ---- remote console (runs on the server) ---------------------------------

net.is_server = true
net.is_admin = true

ThePlayer = NewPlayer("KU_admin")
Run(_G.c_setmission, 3)
Check("c_setmission jumps on the server", LastJump() == 3, LastJump())

-- The console may hand the argument over as a string (and the RPC path
-- always does), so the command must coerce it.
Run(_G.c_setmission, "5")
Check("c_setmission coerces a string argument",
    LastJump() == 5 and type(LastJump()) == "number", LastJump())

local before = #jumps
Run(_G.c_setmission, "abc")
Check("c_setmission rejects a non-number", #jumps == before)
Check("c_setmission prints usage for a non-number",
    OutputContains("Usage: c_setmission(n)"))

Run(_G.c_setmission, 0)
Check("c_setmission reports an out-of-range jump", OutputContains("Invalid mission number"))

Run(_G.c_resetmissions)
Check("c_resetmissions jumps to mission 1", LastJump() == 1, LastJump())

ThePlayer = nil
before = #jumps
Run(_G.c_setmission, 2)
Check("c_setmission without ThePlayer changes nothing", #jumps == before)
Check("c_setmission warns when ThePlayer is nil", OutputContains("no player"))

-- ---- local console (forwards over a mod RPC) -----------------------------

ThePlayer = NewPlayer("KU_admin")
net.is_server = false

before = #jumps
Run(_G.c_setmission, 4)
Check("local c_setmission does not touch the replica", #jumps == before)
Check("local c_setmission sends one RPC", #sent_rpcs == 1)
local sent = sent_rpcs[#sent_rpcs]
Check("local c_setmission sends the setmission RPC",
    sent ~= nil and sent.id_table.id == "setmission", sent ~= nil and sent.id_table.id)
Check("local c_setmission forwards the mission number",
    sent ~= nil and sent.n == 1 and sent.args[1] == 4, sent ~= nil and sent.args[1])

Run(_G.c_resetmissions)
Check("local c_resetmissions sends the resetmissions RPC",
    #sent_rpcs == 2 and sent_rpcs[#sent_rpcs].id_table.id == "resetmissions")

-- ---- RPC handlers (server side) ------------------------------------------

local server_player = NewPlayer("KU_admin")
net.clients.KU_admin = { admin = true }

before = #jumps
local handler = rpc_handlers["guidedmissions/setmission"]
Check("setmission RPC handler registered", type(handler) == "function")
if type(handler) == "function" then
    Run(handler, server_player, 6)
end
Check("setmission RPC handler applies an admin jump", LastJump() == 6, LastJump())

local non_admin = NewPlayer("KU_guest")
net.clients.KU_guest = { admin = false }
before = #jumps
local reset_handler = rpc_handlers["guidedmissions/resetmissions"]
Check("resetmissions RPC handler registered", type(reset_handler) == "function")
if type(handler) == "function" then
    Run(handler, non_admin, 2)
end
if type(reset_handler) == "function" then
    Run(reset_handler, non_admin)
end
Check("RPC handlers reject non-admins", #jumps == before)

if type(reset_handler) == "function" then
    Run(reset_handler, server_player)
end
Check("resetmissions RPC handler applies an admin reset", LastJump() == 1, LastJump())

print(failures == 0 and "ALL PASS" or ("FAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
