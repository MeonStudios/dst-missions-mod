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

-- Mod options the harness feed to modmain. The dropdown default is "session";
-- the harness deliberately asks for "always" so the mapping is observable.
local config_values = {
    SHOW_TRACKER = true,
    ANNOUNCE_MISSIONS = true,
    MULTIPLAYER_MODE = true,
    EMERGENCY_FREQUENCY = "always",
}

local function ModAPI(env)
    env.GetModConfigData = function(name) return config_values[name] end
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

local Settings = require("guidedmissions/settings")
Check("emergency frequency comes from the mod config",
    Settings.emergency_frequency == "always", Settings.emergency_frequency)
Check("multiplayer mode comes from the mod config",
    Settings.multiplayer_mode == true, Settings.multiplayer_mode)

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

-- ---- farmplantable post-init ----------------------------------------------
-- Planting a seed in tilled soil has no vanilla player event; modmain wraps
-- FarmPlantable:Plant to report the seed. A successful Plant removes the seed,
-- so the wrapper must read the prefab first.

local farmplantable_postinit = component_postinits.farmplantable
Check("farmplantable post-init registered", type(farmplantable_postinit) == "function")

local function NewFarmPlantable(planted)
    local component = {
        inst = { prefab = "carrot_seeds" },
        target = { HasTag = function() return true end },
    }
    function component:Plant()
        return planted
    end
    return component
end

if type(farmplantable_postinit) == "function" then
    local component = NewFarmPlantable(true)
    farmplantable_postinit(component)
    local planter = NewChef()
    Check("farmplantable wrapper returns Plant's result",
        component:Plant({}, planter) == true)
    Check("planting reports the seed",
        #planter.events == 1 and planter.events[1].name == "guidedmissions_planted")
    Check("planted event carries the held item's prefab",
        planter.events[1] ~= nil and planter.events[1].data.item == "carrot_seeds")

    -- A refused plant (wrong target, no crop) must report nothing.
    local refused = NewFarmPlantable(false)
    farmplantable_postinit(refused)
    local refused_planter = NewChef()
    Check("refused plant returns false", refused:Plant({}, refused_planter) == false)
    Check("refused plant reports nothing", #refused_planter.events == 0)

    -- No planter must not error.
    local planterless = NewFarmPlantable(true)
    farmplantable_postinit(planterless)
    Check("plant without a planter is safe", planterless:Plant({}) == true)
end

-- ---- deployable post-init -------------------------------------------------
-- Wormwood plants seeds through deployable (restrictedtag "plantkin"); that
-- path spawns the crop directly, so it is reported separately from PLANTSOIL.
-- Dug plants (bushes, grass, saplings) and other plantables are also deployed,
-- recognised by the `deployedplant` tag rather than a farmplantable component.

local deployable_postinit = component_postinits.deployable
Check("deployable post-init registered", type(deployable_postinit) == "function")

-- Both plantable paths are covered: a seed (farmplantable, Wormwood) and a dug
-- plant or other plantable (the `deployedplant` tag, prefabs/plantables.lua:48).
local function NewDeployable(prefab, is_plantable, deployed)
    local component = { inst = { prefab = prefab, components = {} } }
    if is_plantable == "farmplantable" then
        component.inst.components = { farmplantable = {} }
    end
    component.inst.tags = { deployedplant = is_plantable == "deployedplant" }
    function component.inst:HasTag(tag)
        return self.tags[tag] == true
    end
    function component:Deploy()
        return deployed, "reason"
    end
    return component
end

if type(deployable_postinit) == "function" then
    local seed = NewDeployable("seeds", "farmplantable", true)
    deployable_postinit(seed)
    local planter = NewChef()
    local deployed, reason = seed:Deploy({}, planter)
    Check("deployable wrapper returns Deploy's result",
        deployed == true and reason == "reason")
    Check("deploying a seed reports the seed",
        #planter.events == 1 and planter.events[1].name == "guidedmissions_planted")
    Check("planted event carries the held item's prefab",
        planter.events[1] ~= nil and planter.events[1].data.item == "seeds")

    -- A dug plant is planted by deploying it, and reports the dug item id (not
    -- the bush that gets spawned).
    local dug = NewDeployable("dug_berrybush", "deployedplant", true)
    deployable_postinit(dug)
    local dug_planter = NewChef()
    Check("deploying a dug plant succeeds", dug:Deploy({}, dug_planter) == true)
    Check("deploying a dug plant reports it",
        #dug_planter.events == 1
            and dug_planter.events[1].name == "guidedmissions_planted"
            and dug_planter.events[1].data.item == "dug_berrybush")

    -- Deploying anything else (a tent, a boat) is not planting.
    local other = NewDeployable("tent", nil, true)
    deployable_postinit(other)
    local other_planter = NewChef()
    other:Deploy({}, other_planter)
    Check("deploying a non-plantable reports nothing", #other_planter.events == 0)

    -- A refused deploy (CanDeploy false) must report nothing.
    local refused = NewDeployable("dug_grass", "deployedplant", false)
    deployable_postinit(refused)
    local refused_planter = NewChef()
    Check("refused deploy returns false", refused:Deploy({}, refused_planter) == false)
    Check("refused deploy reports nothing", #refused_planter.events == 0)
end

-- ---- trap post-init -------------------------------------------------------
-- The player checks a sprung trap through CHECKTRAP, which calls
-- Trap:Harvest(doer). The objective filters on the trap's stored loot, so the
-- wrapper reports `lootprefabs` before Harvest resets the trap. A sprung trap
-- with no loot caught nothing.

local trap_postinit = component_postinits.trap
Check("trap post-init registered", type(trap_postinit) == "function")

local function NewTrap()
    local component = { issprung = false, lootprefabs = nil }
    function component:Harvest()
        self.harvested = true
    end
    return component
end

if type(trap_postinit) == "function" then
    local trap = NewTrap()
    trap_postinit(trap)
    trap.issprung = true
    trap.lootprefabs = { "rabbit" }
    local doer = NewChef()
    trap:Harvest(doer)
    Check("trap check reports the catch",
        #doer.events == 1 and doer.events[1].name == "guidedmissions_trapchecked")
    Check("trapchecked event carries the loot",
        doer.events[1] ~= nil and doer.events[1].data.loot[1] == "rabbit")
    Check("trap check forwards the harvest behaviour", trap.harvested == true)

    -- A trap that sprang on something untrappable has no loot: no report.
    local empty = NewTrap()
    trap_postinit(empty)
    empty.issprung = true
    local empty_doer = NewChef()
    empty:Harvest(empty_doer)
    Check("empty sprung trap reports nothing", #empty_doer.events == 0)

    -- Used by a tool (no checker) must not error.
    local tool = NewTrap()
    trap_postinit(tool)
    tool.issprung = true
    tool.lootprefabs = { "froglegs" }
    Check("trap check without a doer is safe", tool:Harvest() == nil)
end

-- ---- sleepingbaguser post-init -------------------------------------------
-- Entering a tent emits no vanilla player event. The sleep action calls
-- SleepingBag:DoSleep(doer), which reaches the player's sleepingbaguser
-- component; modmain reports the bed entity to the player so a sleep objective
-- can count entries.

local sleeper_postinit = component_postinits.sleepingbaguser
Check("sleepingbaguser post-init registered", type(sleeper_postinit) == "function")

if type(sleeper_postinit) == "function" then
    local player = NewChef()
    local component = { inst = player }
    function component:DoSleep(bed)
        self.slept_in = bed
    end
    sleeper_postinit(component)

    local bed = { prefab = "tent" }
    component:DoSleep(bed)
    Check("sleep hook forwards the bed to vanilla", component.slept_in == bed)
    Check("sleep hook reports the bed to the player",
        #player.events == 1
            and player.events[1].name == "guidedmissions_slept"
            and player.events[1].data.bed == bed)

    -- No bed (or no player) must not report anything or error.
    local before = #player.events
    component:DoSleep(nil)
    Check("sleep hook ignores a nil bed", #player.events == before)
end

-- ---- pickable post-init (fertilizing) ------------------------------------
-- Fertilizing a barren/withered bush or grass tuft emits no vanilla player
-- event. The FERTILIZE action calls Pickable:Fertilize(fertilizer, doer), so
-- modmain reports the fertilized plant to the player. Farm crops take other
-- branches of the action and never reach this component.

local pickable_postinit = component_postinits.pickable
Check("pickable post-init registered", type(pickable_postinit) == "function")

local function NewPickable(applied)
    local component = { inst = { prefab = "berrybush" } }
    function component:Fertilize()
        self.fertilized = true
        return applied
    end
    return component
end

if type(pickable_postinit) == "function" then
    local plant = NewPickable(true)
    pickable_postinit(plant)
    local doer = NewChef()
    local applied = plant:Fertilize({ prefab = "rot" }, doer)
    Check("pickable wrapper returns Fertilize's result", applied == true)
    Check("fertilizing forwards the vanilla behaviour", plant.fertilized == true)
    Check("fertilizing reports the plant to the player",
        #doer.events == 1
            and doer.events[1].name == "guidedmissions_fertilized"
            and doer.events[1].data.plant == plant.inst)
    Check("fertilized event carries the fertilizer prefab",
        doer.events[1] ~= nil and doer.events[1].data.fertilizer == "rot")

    -- A refused fertilize must report nothing.
    local refused = NewPickable(false)
    pickable_postinit(refused)
    local refused_doer = NewChef()
    Check("refused fertilize returns false", refused:Fertilize({ prefab = "rot" }, refused_doer) == false)
    Check("refused fertilize reports nothing", #refused_doer.events == 0)

    -- No doer (or no fertilizer) must not error.
    local bare = NewPickable(true)
    pickable_postinit(bare)
    Check("fertilizing without a doer is safe", bare:Fertilize() == true)
end

-- ---- fake players ---------------------------------------------------------

local jumps = {}
-- Mission ids the fake manager resolves, mirroring missions.lua.
local mission_ids = { first = 1, second = 2 }
local function NewPlayer(userid)
    local manager = {}
    -- Mirrors GuidedMissionManager:JumpTo's contract: a number or numeric
    -- string is an index, any other string is a mission id, unknown targets
    -- change nothing and return false.
    function manager:JumpTo(target)
        local index = target
        if type(target) == "string" then
            index = tonumber(target) or mission_ids[target]
        end
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
-- always does); the manager resolves a numeric string to that index.
Run(_G.c_setmission, "5")
Check("c_setmission accepts a numeric string argument",
    LastJump() == 5 and type(LastJump()) == "number", LastJump())

Run(_G.c_setmission, "second")
Check("c_setmission jumps by mission id", LastJump() == 2, LastJump())

local before = #jumps
Run(_G.c_setmission, "abc")
Check("c_setmission rejects an unknown id", #jumps == before)
Check("c_setmission reports an unknown id",
    OutputContains("Invalid mission number or id"))

Run(_G.c_setmission)
Check("c_setmission prints usage for no argument",
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

-- A mission id is forwarded as-is; the server-side manager resolves it.
local before_local = #sent_rpcs
Run(_G.c_setmission, "second")
local id_sent = sent_rpcs[#sent_rpcs]
Check("local c_setmission forwards a mission id",
    #sent_rpcs == before_local + 1
    and id_sent.id_table.id == "setmission"
    and id_sent.args[1] == "second",
    id_sent ~= nil and id_sent.args[1])

Run(_G.c_resetmissions)
Check("local c_resetmissions sends the resetmissions RPC",
    #sent_rpcs == 3 and sent_rpcs[#sent_rpcs].id_table.id == "resetmissions")

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

if type(handler) == "function" then
    Run(handler, server_player, "first")
end
Check("setmission RPC handler resolves a mission id", LastJump() == 1, LastJump())

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

-- ---- unknown mod option values -------------------------------------------
-- An old or malformed config must not disable emergencies: modmain sanitises
-- the value back to the default ("session").

config_values.EMERGENCY_FREQUENCY = "nonsense"
local reloaded = assert(loadfile(root .. "/modmain.lua"))
setfenv(reloaded, env)
Check("modmain reloads with an unknown frequency", pcall(reloaded))
Check("unknown emergency frequency falls back to session",
    Settings.emergency_frequency == "session", Settings.emergency_frequency)

print(failures == 0 and "ALL PASS" or ("FAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
