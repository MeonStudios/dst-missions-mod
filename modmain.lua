-- modmain runs in a sandboxed environment (mods.lua CreateEnvironment) that
-- whitelists only pairs/ipairs/print/math/table/type/string/tostring/require/
-- Class. There is no fallback to _G, so any other base-library function must be
-- reached through GLOBAL. Missing `tonumber` is what broke c_setmission()
-- originally; the commands below stick to `type`/`tostring` instead.
local GLOBAL = GLOBAL

local MissionNetvars = require("guidedmissions/netvars")
local Settings = require("guidedmissions/settings")

-- The tracker draws the world flower's animation for pick rows (flowers are
-- world plants with no inventory icon), so the client needs the vanilla anim
-- loaded. HUD widgets do not inherit a prefab's asset list.
Assets = {
    Asset("ANIM", "anim/flowers.zip"),
}

Settings.show_tracker = GetModConfigData("SHOW_TRACKER") ~= false
Settings.announce_missions = GetModConfigData("ANNOUNCE_MISSIONS") ~= false

-- Admin testing commands, callable from the debug console (`~`):
--   c_resetmissions()   restart your chain from mission 1
--   c_setmission(n)     jump to mission n (1-based, order of missions.lua)
--   c_setmission("id")  jump to the mission with that id (quote it; ids are
--                       the lowercase `id` field in missions.lua)
-- They are real globals because the console's autocomplete scans `_G` for
-- functions starting with `c_` (screens/consolescreen.lua). Slash commands are
-- not an option: the redux chat box sends every line with TheNet:Say and never
-- parses "/commands".
--
-- In an in-game admin's console the default is remote execute: the string runs
-- on the server with ThePlayer temporarily set to the caller's server-side
-- entity (mainfunctions.lua, ExecuteConsoleCommand), so the manager is reachable
-- directly. In local mode the command runs in the client VM, where ThePlayer
-- only has replicas, so it is forwarded over a mod RPC.
local RPC_NAMESPACE = "guidedmissions"

local function IsAdmin(player)
    local client = player ~= nil and player.userid ~= nil
        and GLOBAL.TheNet:GetClientTableForUser(player.userid) or nil
    return client ~= nil and client.admin == true
end

local function ApplyJump(player, target)
    local manager = player ~= nil and player.components.guidedmissionmanager or nil
    if manager == nil then
        return
    end
    if not manager:JumpTo(target) then
        print("[Guided Missions] Invalid mission number or id: " .. tostring(target))
    end
end

AddModRPCHandler(RPC_NAMESPACE, "setmission", function(player, target)
    -- Any client can send an RPC, so re-check admin on the server.
    if IsAdmin(player) then
        ApplyJump(player, target)
    end
end)

AddModRPCHandler(RPC_NAMESPACE, "resetmissions", function(player)
    if IsAdmin(player) then
        ApplyJump(player, 1)
    end
end)

GLOBAL.c_resetmissions = function()
    if GLOBAL.TheNet:GetIsServer() then
        if GLOBAL.ThePlayer == nil then
            print("[Guided Missions] c_resetmissions: no player; run it from an in-game admin's Remote console")
            return
        end
        ApplyJump(GLOBAL.ThePlayer, 1)
    elseif GLOBAL.TheNet:GetIsServerAdmin() then
        SendModRPCToServer(GetModRPC(RPC_NAMESPACE, "resetmissions"))
    end
end

GLOBAL.c_setmission = function(target)
    -- A number or numeric string is a 1-based mission index; any other string
    -- is a mission id ("green_thumb"). The manager resolves either.
    if type(target) ~= "number" and type(target) ~= "string" then
        print("[Guided Missions] Usage: c_setmission(n) or c_setmission(\"mission_id\")")
        return
    end

    if GLOBAL.TheNet:GetIsServer() then
        if GLOBAL.ThePlayer == nil then
            print("[Guided Missions] c_setmission: no player; run it from an in-game admin's Remote console")
            return
        end
        ApplyJump(GLOBAL.ThePlayer, target)
    elseif GLOBAL.TheNet:GetIsServerAdmin() then
        SendModRPCToServer(GetModRPC(RPC_NAMESPACE, "setmission"), target)
    end
end

-- Netvars must be declared identically on the server and on every client,
-- otherwise entity deserialization will fail. Always attach, even if the
-- local player has the tracker disabled.
AddPlayerPostInit(function(inst)
    MissionNetvars.Attach(inst)

    -- Gameplay state is server-authoritative.
    if GLOBAL.TheNet:GetIsServer() and inst.components.guidedmissionmanager == nil then
        inst:AddComponent("guidedmissionmanager")
    end
end)

-- Vanilla fire cooking emits no player event, so observe the `cooker` component
-- (campfire, firepit, lighter). This returns CookItem's result untouched and
-- only reports a successful cook to the chef, whose manager listens for it. The
-- crockpot uses the `stewer` component instead, so it is deliberately excluded.
AddComponentPostInit("cooker", function(self)
    local _CookItem = self.CookItem
    self.CookItem = function(component, item, chef)
        local product = _CookItem(component, item, chef)
        if product ~= nil and chef ~= nil
            and product.components ~= nil and product.components.edible ~= nil then
            chef:PushEvent("guidedmissions_cookedfood", { ingredient = item, product = product })
        end
        return product
    end
end)

-- Vanilla `sanitydelta` carries no amount (`components/sanity.lua:405`, unlike
-- `healthdelta`'s `amount`), and DoDelta clamps at the bar's ends, so a sanity
-- gain at full sanity is invisible in the event. Record the requested delta on
-- the component just before vanilla runs; the manager's sanity objective reads
-- it as `_guidedmissions_last_delta` and credits the full requested amount,
-- including the part that overflowed. The component's behaviour is unchanged.
AddComponentPostInit("sanity", function(self)
    local _DoDelta = self.DoDelta
    self.DoDelta = function(component, delta, overtime)
        component._guidedmissions_last_delta = delta
        return _DoDelta(component, delta, overtime)
    end
end)

-- Crockpots use `stewer`, not `cooker`, and also emit no player event.
-- StartCooking(doer) calculates the finished dish, so report it to the chef
-- once the pot actually starts (not when it is already cooking).
AddComponentPostInit("stewer", function(self)
    local _StartCooking = self.StartCooking
    self.StartCooking = function(component, doer)
        local was_cooking = component:IsCooking()
        local result = _StartCooking(component, doer)
        if not was_cooking and component:IsCooking()
            and component.product ~= nil
            and doer ~= nil and doer.PushEvent ~= nil then
            doer:PushEvent("guidedmissions_stewedfood", {
                product = component.product,
                ingredients = component.ingredient_prefabs,
            })
        end
        return result
    end
end)

-- Planting a seed in tilled farm soil emits no player event. The seed item
-- (`seeds`, `carrot_seeds`, ...) carries the `farmplantable` component, and the
-- PLANTSOIL action calls FarmPlantable:Plant(target, planter); report the seed
-- to the planter when that returns true. Capture the prefab before the call:
-- a successful Plant removes the seed entity. See docs/dst-api.md, "Farming".
AddComponentPostInit("farmplantable", function(self)
    local _Plant = self.Plant
    self.Plant = function(component, target, planter)
        local seed_prefab = component.inst.prefab
        local planted = _Plant(component, target, planter)
        if planted and planter ~= nil and planter.PushEvent ~= nil then
            planter:PushEvent("guidedmissions_plantedseed", { seed = seed_prefab })
        end
        return planted
    end
end)

-- Wormwood is the only `plantkin`, so seeds are deployable for him and only
-- him (`deployable.restrictedtag = "plantkin"`); that path calls the seed's
-- ondeploy callback directly instead of FarmPlantable:Plant. Report it with
-- the same event. `is_seed` is read before the call because a successful
-- deploy removes the seed.
AddComponentPostInit("deployable", function(self)
    local _Deploy = self.Deploy
    self.Deploy = function(component, pt, deployer, rot)
        local inst = component.inst
        local is_seed = inst ~= nil and inst.components ~= nil
            and inst.components.farmplantable ~= nil
        local seed_prefab = inst ~= nil and inst.prefab or nil
        local deployed, reason = _Deploy(component, pt, deployer, rot)
        if is_seed and deployed and deployer ~= nil and deployer.PushEvent ~= nil then
            deployer:PushEvent("guidedmissions_plantedseed", { seed = seed_prefab })
        end
        return deployed, reason
    end
end)

-- Traps. The player learns what they caught only when they check the trap:
-- the CHECKTRAP action calls `Trap:Harvest(doer)` (`actions.lua:1686-1689`).
-- The trap's stored loot is what the objective filters on, so report it to the
-- checker. `lootprefabs` is read before Harvest, which resets the trap. A
-- sprung trap with no loot caught nothing and is ignored.
AddComponentPostInit("trap", function(self)
    local _Harvest = self.Harvest
    self.Harvest = function(component, doer)
        local loot = component.lootprefabs
        local had_catch = component.issprung and loot ~= nil and #loot > 0
        local result = _Harvest(component, doer)
        if had_catch and doer ~= nil and doer.PushEvent ~= nil then
            doer:PushEvent("guidedmissions_trapchecked", { loot = loot })
        end
        return result
    end
end)

-- Client HUD. Dedicated servers have no local player, so skip the hook there.
if not GLOBAL.TheNet:IsDedicated() and Settings.show_tracker then
    AddPrefabPostInit("world", function(world)
        world:ListenForEvent("playeractivated", function(_, player)
            if player ~= GLOBAL.ThePlayer then
                return
            end

            if player._guidedmissiontracker ~= nil then
                return
            end

            if player.HUD == nil or player.HUD.root == nil then
                return
            end

            local MissionTracker = require("widgets/guidedmissiontracker")

            -- Dock to the vanilla top-right HUD scaling root so the card shares
            -- the HUD's anchors and size setting (the widget itself stays a
            -- plain child and must not scale on its own, or it compounds).
            -- The top-right corner is where the clock and the health/hunger/
            -- sanity badges live (controls.sidepanel), so the card hugs them
            -- instead of fighting the insight button and gift toasts on the left.
            local controls = player.HUD.controls
            local parent = controls ~= nil and controls.topright_root or nil
            if parent == nil then
                -- Should not happen: SetMainCharacter builds controls before
                -- playeractivated. Keep a top-right dock as a safety net.
                local Widget = require("widgets/widget")
                parent = player.HUD.root:AddChild(Widget("guidedmission_dock"))
                parent:SetHAnchor(GLOBAL.ANCHOR_RIGHT)
                parent:SetVAnchor(GLOBAL.ANCHOR_TOP)
                parent:SetScaleMode(GLOBAL.SCALEMODE_PROPORTIONAL)
                parent:SetMaxPropUpscale(GLOBAL.MAX_HUD_SCALE)
            end

            player._guidedmissiontracker = parent:AddChild(MissionTracker(player))
        end)
    end)
end
