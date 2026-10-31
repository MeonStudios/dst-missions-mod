local GLOBAL = GLOBAL

local MissionNetvars = require("guidedmissions/netvars")
local Settings = require("guidedmissions/settings")

Settings.show_tracker = GetModConfigData("SHOW_TRACKER") ~= false
Settings.announce_missions = GetModConfigData("ANNOUNCE_MISSIONS") ~= false

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
            player._guidedmissiontracker = player.HUD.root:AddChild(MissionTracker(player))
        end)
    end)
end
