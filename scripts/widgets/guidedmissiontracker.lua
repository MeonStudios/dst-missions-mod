local Widget = require("widgets/widget")
local Text = require("widgets/text")
local Image = require("widgets/image")

local Netvars = require("guidedmissions/netvars")

local PANEL_WIDTH = 370
local PANEL_HEIGHT = 112
local MARGIN_X = 24
local MARGIN_TOP = 300

local MissionTracker = Class(Widget, function(self, owner)
    Widget._ctor(self, "GuidedMissionTracker")
    self.owner = owner

    -- Widget children are positioned relative to the widget origin, and the
    -- origin is what gets anchored. Center the panel in its own coordinate
    -- space so the background does not hang off the left/top screen edges.
    self:SetHAnchor(ANCHOR_LEFT)
    self:SetVAnchor(ANCHOR_TOP)
    self:SetPosition(MARGIN_X + PANEL_WIDTH / 2, -(MARGIN_TOP + PANEL_HEIGHT / 2))

    self.bg = self:AddChild(Image("images/global.xml", "square.tex"))
    self.bg:SetTint(0, 0, 0, 0.62)
    self.bg:SetSize(PANEL_WIDTH, PANEL_HEIGHT)

    self.title = self:AddChild(Text(DEFAULTFONT, 22, "", { 1, 0.84, 0.35, 1 }))
    self.title:SetPosition(0, 34)

    self.body = self:AddChild(Text(DEFAULTFONT, 18, "", { 1, 1, 1, 1 }))
    self.body:SetPosition(0, 2)
    self.body:SetRegionSize(340, 52)
    self.body:SetHAlign(ANCHOR_MIDDLE)
    self.body:SetVAlign(ANCHOR_MIDDLE)

    self.footer = self:AddChild(Text(DEFAULTFONT, 15, "", { 0.72, 0.72, 0.72, 1 }))
    self.footer:SetPosition(0, -38)

    owner:ListenForEvent(Netvars.DIRTY_EVENT, function()
        self:Refresh()
    end)

    self:Refresh()
end)

function MissionTracker:Refresh()
    if self.owner == nil or not self.owner:IsValid() then
        return
    end

    local state = Netvars.Read(self.owner)
    if state.title == "" then
        self:Hide()
        return
    end

    self:Show()
    self.title:SetString(state.title)
    self.body:SetString(state.objectives)
    self.footer:SetString(state.footer)
end

return MissionTracker
