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
