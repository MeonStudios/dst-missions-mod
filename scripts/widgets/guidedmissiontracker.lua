-- Client HUD for the guided mission chain.
--
-- Pure renderer: the server writes the five netvar strings (title, subtext,
-- rows, state, hint) and this widget only draws them. It never sends progress
-- back and never changes game state.
--
-- Docking: modmain adds this widget to player.HUD.controls.topright_root, the
-- vanilla top-right HUD scaling root. It is a plain child (no anchors or scale
-- of its own) so it inherits that root's right/top origin and HUD size scale
-- instead of applying a second, compounding scale. Local coordinates start at
-- the screen's top-right corner; x is negative to the left, y negative down.
-- The card's x comes from measuring the health/hunger/sanity badge cluster
-- (MeasureRightMargin), so it hugs them whatever size a mod gives them. A DST
-- Text's SetPosition is the CENTER of its region, so every left/right-aligned
-- label sets an explicit region size and positions the region's center (not
-- its edge).

local Widget = require("widgets/widget")
local Text = require("widgets/text")
local Image = require("widgets/image")
local ImageButton = require("widgets/imagebutton")
local UIAnim = require("widgets/uianim")

local Netvars = require("guidedmissions/netvars")
local L10n = require("guidedmissions/l10n")
local Strings = require("guidedmissions/strings")

local CRAFTING_ATLAS = "images/crafting_menu.xml"
local UI_ATLAS = "images/ui.xml"
local HINT_ATLAS = "images/skilltree.xml"

-- Icon ids that use a static UI texture instead of an inventory image.
-- `brain` and `heart` are the ids the sanity and heal objectives use; the
-- textures are the brain and heart glyphs from the HUD status badges.
-- `images/global_redux.xml` is preloaded by the global prefab
-- (`scripts/prefabs/global.lua:456`), so no Assets entry is needed.
local ICON_IMAGES = {
    brain = { "images/global_redux.xml", "status_sanity.tex" },
    heart = { "images/global_redux.xml", "status_health.tex" },
}

-- Icon ids drawn from a vanilla world animation. `flower` is a world plant
-- with no inventory icon, and the scrapbook art is a framed picture; drawing
-- the anim shows the same flower art the world uses (bank/build "flowers",
-- animations f1..f10, `prefabs/flower.lua:145-147`). modmain declares the anim
-- asset so the client has it loaded.
local ICON_ANIMS = {
    flower = { bank = "flowers", build = "flowers", animation = "f1" },
}

local CARD_W = 320
local ROW_H = 42
-- Optional objectives are grouped below the required ones under this heading;
-- the card grows by exactly this much when a mission has any.
local OPTIONAL_HEADER_H = 30
local BANNER_H = 38
local STRIP_H = 59
local STRIP_TITLE_MARGIN = 6
-- Drop both bottom rails so the banner's centre relief sits below the fill
-- edge (over the dark world) instead of showing the light wood through it.
local BOTTOM_FRAME_DROP = 10
local SIDE_W = 26
local SIDE_INSET = 3      -- geometry centre, so the visible plank is flush with the edge
-- side.tex is 44x1023; draw it at its natural aspect and scissor it to the
-- panel. Stretching 1023 rows into ~140 is what made the planks look blurry.
local SIDE_ASPECT = 1023 / 44
local CONTENT_PAD = 18    -- content starts this far inside the card edge
-- The banner art (in display orientation) has transparent margins: the top
-- banner's opaque bar is drawn ~15-25 px into the 38 px strip, and the bottom
-- banner's bar ends ~13 px above the card bottom. Insetting the fill by 16 px
-- tucks both fill edges under the wooden bars instead of letting the fill show
-- above/below the frame.
local FILL_INSET = 16
-- The card hugs the health/hunger/sanity cluster in the top-right corner.
-- The distance from the screen edge is measured at layout time from the
-- badges themselves (see MeasureRightMargin), so a mod that moves or enlarges
-- them -- Combined Status does both -- is followed automatically.
local DEFAULT_RIGHT_MARGIN = 200  -- used when the status display cannot be read
local STATUS_GAP = 30             -- gap between the card and the nearest badge
local BADGE_HALF_W = 48           -- half the width of a status badge
local MARGIN_TOP = 4
-- The card docks at the measured margin by default, but each player can drag
-- it left or right with the mouse. The offset is saved per account in
-- client_save. Coordinates are the dock root's local space: x = 0 is the
-- screen's right edge and the left edge is negative.
local DOCK_FILE = "mod_config_data/guidedmissions_tracker_position"
local DOCK_EDGE_PAD = 8   -- gap kept between the card and either screen edge
-- The collapsed strip is flush with the top edge of the screen (its open top
-- needs no cap), unlike the expanded card which keeps a small margin.
local STRIP_MARGIN_TOP = 0

-- Vertical content stack. Everything (title included) lives inside the fill,
-- below the top bar and above the bottom bar; the frame is drawn around it.
local TOP_SAFE = 34       -- card top -> title band (clears the top banner bar + margin)
local TITLE_H = 30
local TITLE_GAP = 4
local ROWS_GAP = 6        -- last row -> divider
local DIVIDER_H = 4
local DIVIDER_GAP = 5     -- divider -> subtext
local SUBTEXT_H = 24
-- Distance from the subtext to the card bottom, excluding the dropped rail.
-- The rail hangs BOTTOM_FRAME_DROP below the card, so this is 10 smaller than
-- the visual margin would otherwise be; it keeps the subtext centred between
-- the divider and the rail bar.
local BOTTOM_SAFE = 20
local CARD_BASE_H = TOP_SAFE + TITLE_H + TITLE_GAP + ROWS_GAP
    + DIVIDER_H + DIVIDER_GAP + SUBTEXT_H + BOTTOM_SAFE

local ICON_SIZE = 36
local ICON_GAP = 8        -- icon -> counter
local CHEVRON_SIZE = 34
local CHECK_SIZE = 24

-- The optional hint button. `question.tex` / `question_over.tex` are the
-- skill-tree's question emblem ("images/skilltree.xml", used at
-- widgets/redux/skilltreebuilder.lua:719); the atlas is preloaded by the
-- global prefab (prefabs/global.lua:490), so no Assets entry is needed. The
-- icon is 44x44 art, drawn smaller to sit beside the 34px chevron.
local HINT_BUTTON_SIZE = 26
local HINT_BUTTON_GAP = 6
-- The hover text hangs below the button (negative y) instead of the vanilla
-- default above it, because the card is flush with the top of the screen.
-- Width is capped and the text is pre-wrapped: the hover backing is drawn from
-- the measured text extent, and an unwrapped hint would run off the HUD.
local HINT_TOOLTIP_W = 240
local HINT_TOOLTIP_FONT_SIZE = 20
local HINT_TOOLTIP_MAX_LINES = 4
local HINT_TOOLTIP_GAP = 2   -- button bottom -> tooltip backing top
local HINT_TOOLTIP_PAD = 20  -- backing margin above and below the text

local SLIDE_TIME = 0.25
local STEP_OFFSCREEN_Y = 60
local DONE_HIDE_DELAY = 2.5
local STING_EVENT = "wilson_rework/ui/skill_mastered"
local STING_VOLUME = 0.6

-- Column geometry. Labels always start at the content edge (in line with the
-- title/subtext); the item icon is placed immediately left of the counter,
-- whose width is measured at runtime:
--   Collect flint            [icon] 0/3
local function MakeColumns(pad)
    local left = -CARD_W / 2 + pad
    local right = CARD_W / 2 - pad
    local chevron_x = right - CHEVRON_SIZE / 2
    local title_w = (chevron_x - CHEVRON_SIZE / 2 - 8) - left
    -- A mission with a hint hangs the "?" immediately after the title, so the
    -- title band gives up the button's width. The longest mission title is
    -- ~176px, and this still leaves ~210px, so nothing is truncated.
    return {
        left = left,
        right = right,
        chevron_x = chevron_x,
        check_x = right - CHECK_SIZE / 2,
        title_w = title_w,
        title_cx = left + title_w / 2,
        max_hint_title_w = title_w - HINT_BUTTON_SIZE - HINT_BUTTON_GAP,
        subtext_w = right - left,
        subtext_cx = left + (right - left) / 2,
    }
end

local COLUMNS = MakeColumns(CONTENT_PAD)

local function Split(text, sep)
    local parts = {}
    local start = 1
    while true do
        local pos = string.find(text, sep, start, true)
        if pos == nil then
            parts[#parts + 1] = string.sub(text, start)
            return parts
        end
        parts[#parts + 1] = string.sub(text, start, pos - 1)
        start = pos + #sep
    end
end

local function MakeChevron(normal_tex, focus_tex, onclick)
    local button = ImageButton(
        CRAFTING_ATLAS,
        normal_tex,
        focus_tex,
        nil, nil, nil,
        { 1, 1 },
        { 0, 0 }
    )
    button:ForceImageSize(CHEVRON_SIZE, CHEVRON_SIZE)
    button:SetOnClick(onclick)
    return button
end

local MissionTracker = Class(Widget, function(self, owner)
    Widget._ctor(self, "GuidedMissionTracker")
    self.owner = owner

    self.last_state = nil
    self.last_payload = nil
    self.expanded = true
    self.transitioning = false
    self.hide_task = nil
    self.row_widgets = {}
    self.card_h = CARD_BASE_H

    self.card_open_pos = Vector3(0, 0, 0)
    self.card_offscreen_pos = Vector3(0, 0, 0)
    self.strip_open_pos = Vector3(0, 0, 0)
    self.default_x = 0
    self.dock_x = 0
    self.drag_offset = 0
    self.dragging = false

    self.card = self:AddChild(Widget("guidedmission_card"))

    -- A transparent, clickable backing covering the card makes the whole
    -- panel a drag handle. Everything drawn above it is SetClickable(false)
    -- and the chevron and "?" are added later, so they stay on top and keep
    -- receiving their clicks.
    self.card_hit = self.card:AddChild(Image(UI_ATLAS, "blank.tex"))
    self.card_hit:SetClickable(true)

    -- The crafting menu's dark translucent backing, like the real panel.
    self.card_fill = self.card:AddChild(Image(CRAFTING_ATLAS, "backing.tex"))
    self.card_fill:SetTint(1, 1, 1, 0.5)
    self.card_fill:SetClickable(false)

    -- The side planks are drawn at their natural aspect and clipped to the
    -- panel window, so the wood grain stays sharp.
    self.card_clip = self.card:AddChild(Widget("guidedmission_clip"))

    self.card_left = self.card_clip:AddChild(Image(CRAFTING_ATLAS, "side.tex"))
    self.card_left:SetClickable(false)

    self.card_right = self.card_clip:AddChild(Image(CRAFTING_ATLAS, "side.tex"))
    self.card_right:SetClickable(false)

    self.card_banner = self.card:AddChild(Image(CRAFTING_ATLAS, "top.tex"))
    self.card_banner:SetClickable(false)

    self.card_bottom = self.card:AddChild(Image(CRAFTING_ATLAS, "bottom.tex"))
    self.card_bottom:SetClickable(false)

    self.card_title = self.card:AddChild(Text(UIFONT, 28, "", UICOLOURS.HIGHLIGHT_GOLD))
    self.card_title:SetHAlign(ANCHOR_LEFT)
    self.card_title:SetVAlign(ANCHOR_MIDDLE)
    self.card_title:SetClickable(false)

    -- Expanded: chevron points up (collapse).
    self.card_chevron = self.card:AddChild(MakeChevron(
        "scrollbar_arrow_up.tex",
        "scrollbar_arrow_up_hl.tex",
        function() self:SetExpanded(false) end
    ))

    -- Optional hint: a "?" between the title and the chevron. Hovering it shows
    -- the mission's hint as a wrapped tooltip; there is no click behaviour.
    -- Hidden whenever the current mission has no hint.
    self.card_hint_button = self.card:AddChild(ImageButton(
        HINT_ATLAS,
        "question.tex",
        "question_over.tex",
        nil, nil, nil,
        { 1, 1 },
        { 0, 0 }
    ))
    self.card_hint_button:ForceImageSize(HINT_BUTTON_SIZE, HINT_BUTTON_SIZE)
    self.card_hint_button:Hide()

    self.row_root = self.card:AddChild(Widget("guidedmission_rows"))

    -- The same thin divider the crafting menu draws under a recipe name
    -- (craftingmenu_details.lua:351-354), instead of the ornate horizontal bar.
    self.card_divider = self.card:AddChild(Image(UI_ATLAS, "line_horizontal_white.tex"))
    self.card_divider:SetTint(unpack(BROWN))
    self.card_divider:SetClickable(false)

    self.card_subtext = self.card:AddChild(Text(BODYTEXTFONT, 20, "", UICOLOURS.IVORY_70))
    self.card_subtext:SetHAlign(ANCHOR_LEFT)
    self.card_subtext:SetVAlign(ANCHOR_MIDDLE)
    self.card_subtext:SetClickable(false)

    self.strip = self:AddChild(Widget("guidedmission_strip"))

    self.strip_hit = self.strip:AddChild(Image(UI_ATLAS, "blank.tex"))
    self.strip_hit:SetClickable(true)

    -- Collapsed: the box's underside (bottom banner over the dark fill) with
    -- the title, and a down chevron to expand again.
    self.strip_fill = self.strip:AddChild(Image(CRAFTING_ATLAS, "backing.tex"))
    self.strip_fill:SetTint(1, 1, 1, 0.5)
    self.strip_fill:SetClickable(false)

    -- Side planks, natural aspect + scissor, same as the expanded card.
    self.strip_clip = self.strip:AddChild(Widget("guidedmission_strip_clip"))
    self.strip_left = self.strip_clip:AddChild(Image(CRAFTING_ATLAS, "side.tex"))
    self.strip_left:SetClickable(false)
    self.strip_right = self.strip_clip:AddChild(Image(CRAFTING_ATLAS, "side.tex"))
    self.strip_right:SetClickable(false)

    self.strip_banner = self.strip:AddChild(Image(CRAFTING_ATLAS, "bottom.tex"))
    self.strip_banner:SetClickable(false)

    self.strip_title = self.strip:AddChild(Text(UIFONT, 28, "", UICOLOURS.HIGHLIGHT_GOLD))
    self.strip_title:SetHAlign(ANCHOR_LEFT)
    self.strip_title:SetVAlign(ANCHOR_MIDDLE)
    self.strip_title:SetClickable(false)

    self.strip_chevron = self.strip:AddChild(MakeChevron(
        "scrollbar_arrow_down.tex",
        "scrollbar_arrow_down_hl.tex",
        function() self:SetExpanded(true) end
    ))

    self:Layout(0)
    self.card:Hide()
    self.strip:Hide()
    self:Hide()

    owner:ListenForEvent(Netvars.DIRTY_EVENT, function()
        self:Refresh()
    end)

    self:LoadDragOffset()
    self:Refresh()
end)

-- ---------------------------------------------------------------- layout

-- Distance from the screen's right edge to the left edge of the status
-- badges, plus a gap. Widgets do not expose their pixel size, so this takes
-- the leftmost *visible* badge's world position and backs off by half a
-- badge. Parents are both top-right anchored, so the result is directly
-- usable as this widget's local x.
function MissionTracker:MeasureRightMargin()
    local hud = self.owner ~= nil and self.owner.HUD or nil
    local status = hud ~= nil and hud.controls ~= nil and hud.controls.status or nil
    local parent = self:GetParent()
    if status == nil or parent == nil then
        return DEFAULT_RIGHT_MARGIN
    end

    local left = nil
    for _, child in ipairs(status:GetChildren()) do
        if child:IsVisible() then
            local p = child:GetWorldPosition()
            if left == nil or p.x < left then
                left = p.x
            end
        end
    end
    if left == nil then
        return DEFAULT_RIGHT_MARGIN
    end

    -- `GetScale` is the recursive (parent-multiplied) scale; `GetWorldScale`
    -- is not implemented in this build (see docs/dst-api.md).
    local scale = parent:GetScale().x
    if scale == nil or scale == 0 then
        scale = 1
    end

    local margin = (parent:GetWorldPosition().x - left) / scale + BADGE_HALF_W + STATUS_GAP

    -- Never let a strange HUD push the card off the screen or over the badges.
    return math.max(margin, CARD_W / 2 + 8)
end

-- Keep the whole card on screen. x is the card centre in dock-root units.
function MissionTracker:ClampDockX(x)
    local width = self:MeasureScreenWidth()
    if width == nil then
        return x
    end
    local min_x = -width + CARD_W / 2 + DOCK_EDGE_PAD
    local max_x = -CARD_W / 2 - DOCK_EDGE_PAD
    if min_x > max_x then
        return (min_x + max_x) / 2
    end
    if x < min_x then
        return min_x
    elseif x > max_x then
        return max_x
    end
    return x
end

-- Width of the screen in the dock root's local units, measured between the
-- two top HUD anchors (both top-anchored scaling roots). nil before the HUD
-- has been laid out, in which case clamping is skipped.
function MissionTracker:MeasureScreenWidth()
    local hud = self.owner ~= nil and self.owner.HUD or nil
    local controls = hud ~= nil and hud.controls or nil
    local left_root = controls ~= nil and controls.topleft_root or nil
    local parent = self:GetParent()
    if left_root == nil or parent == nil then
        return nil
    end
    local scale = parent:GetScale().x
    if scale == nil or scale == 0 then
        return nil
    end
    local width = (parent:GetWorldPosition().x - left_root:GetWorldPosition().x) / scale
    return width > 0 and width or nil
end

-- Recompute the dock positions from the default margin plus the player's drag
-- offset, then move the visible panel there. Layout and a live drag both go
-- through here so the open, off-screen and collapsed positions agree.
function MissionTracker:ApplyDockX()
    local h = self.card_h
    local x = self:ClampDockX(self.default_x + self.drag_offset)
    self.drag_offset = x - self.default_x
    self.dock_x = x

    self.card_open_pos = Vector3(x, -(MARGIN_TOP + h / 2), 0)
    self.card_offscreen_pos = self.card_open_pos + Vector3(0, MARGIN_TOP + h + STEP_OFFSCREEN_Y, 0)
    self.strip_open_pos = Vector3(x, -(STRIP_MARGIN_TOP + STRIP_H / 2), 0)

    if not self.transitioning then
        if self.expanded then
            self.card:SetPosition(self.card_open_pos)
        else
            self.card:SetPosition(self.card_offscreen_pos)
            self.strip:SetPosition(self.strip_open_pos)
        end
    end
end

-- A drag starts only on our own card surface. The chevron and "?" buttons sit
-- on top of the hit area and must keep their clicks, so the deepest focused
-- widget decides; the hover-focus chain also guarantees the click is ours.
function MissionTracker:CanStartDrag()
    if self.dragging or self.transitioning or not self:IsVisible()
        or TheInput == nil or TheFrontEnd == nil
        or TheFrontEnd.GetFocusWidget == nil then
        return false
    end
    local focus = TheFrontEnd:GetFocusWidget()
    return focus ~= nil
        and focus ~= self.card_chevron
        and focus ~= self.strip_chevron
        and focus ~= self.card_hint_button
end

function MissionTracker:StartDrag()
    if not self:CanStartDrag() then
        return false
    end
    self.dragging = true
    self.drag_start_offset = self.drag_offset
    self.drag_last_mouse_x = TheInput:GetScreenPosition().x
    self:StartUpdating()
    return true
end

function MissionTracker:StopDrag()
    if not self.dragging then
        return
    end
    self.dragging = false
    self:StopUpdating()
    -- A plain click (no movement) must not rewrite the saved position.
    if self.drag_offset ~= self.drag_start_offset then
        self:SaveDragOffset()
    end
end

-- Follow the cursor while the left button is held. The move is applied as a
-- screen-space delta divided by the HUD scale, so the card keeps up exactly
-- at any HUD size; ClampDockX keeps it on screen.
function MissionTracker:OnUpdate(dt)
    if self.inst == nil or not self.inst:IsValid() then
        return
    end
    if TheInput == nil or TheInput.IsMouseDown == nil
        or not TheInput:IsMouseDown(MOUSEBUTTON_LEFT) then
        self:StopDrag()
        return
    end

    local parent = self:GetParent()
    local scale = parent ~= nil and parent:GetScale().x or nil
    if scale == nil or scale == 0 then
        scale = 1
    end

    local mx = TheInput:GetScreenPosition().x
    if mx ~= self.drag_last_mouse_x then
        self.drag_offset = self.drag_offset + (mx - self.drag_last_mouse_x) / scale
        self.drag_last_mouse_x = mx
        self:ApplyDockX()
    end
end

-- The hit areas are plain Images, so nothing below consumes a card click;
-- swallow CONTROL_ACCEPT here or it falls through to the world and moves or
-- attacks toward the cursor.
function MissionTracker:OnControl(control, down)
    if Widget.OnControl(self, control, down) then
        return true
    end
    return control == CONTROL_ACCEPT
end

function MissionTracker:OnMouseButton(button, down, x, y)
    if Widget.OnMouseButton(self, button, down, x, y) then
        return true
    end
    if button ~= MOUSEBUTTON_LEFT then
        return false
    end
    if down then
        return self:StartDrag()
    end
    self:StopDrag()
    return true
end

-- client_save is per account, so every player keeps their own position.
function MissionTracker:SaveDragOffset()
    if TheSim == nil or TheSim.SetPersistentString == nil then
        return
    end
    TheSim:SetPersistentString(DOCK_FILE, tostring(self.drag_offset), false)
end

function MissionTracker:LoadDragOffset()
    if TheSim == nil or TheSim.GetPersistentString == nil then
        return
    end
    TheSim:GetPersistentString(DOCK_FILE, function(success, data)
        if not success or data == nil or data == "" or not self.inst:IsValid() then
            return
        end
        local saved = tonumber(data)
        if saved == nil then
            return
        end
        self.drag_offset = saved
        self:ApplyDockX()
    end)
end

function MissionTracker:Layout(row_count, has_hint, title_width, has_optional)
    local h = CARD_BASE_H + ROW_H * row_count
        + (has_optional and OPTIONAL_HEADER_H or 0)
    self.card_h = h
    self.default_x = -(self:MeasureRightMargin() + CARD_W / 2)
    self:ApplyDockX()

    local top = h / 2

    self.card_hit:SetSize(CARD_W, h)
    self.card_hit:SetPosition(0, 0)

    self.card_fill:SetSize(CARD_W, h - FILL_INSET * 2)
    self.card_fill:SetPosition(0, 0)

    -- Scissor is anchored bottom-left, not centre.
    self.card_clip:SetScissor(-CARD_W / 2, -h / 2 + FILL_INSET, CARD_W, h - FILL_INSET * 2)

    -- side.tex has transparent margins: its art occupies columns ~8-27 of 44,
    -- so the visible plank is narrower than the image. Mirror the left copy
    -- (as the crafting menu does) and inset the centres so both planks are
    -- flush with the card edges instead of floating outside them.
    local side_h = SIDE_W * SIDE_ASPECT
    self.card_left:SetSize(SIDE_W, side_h)
    self.card_left:SetScale(-1, 1, 1)
    self.card_left:SetPosition(-CARD_W / 2 + SIDE_INSET, 0)

    self.card_right:SetSize(SIDE_W, side_h)
    self.card_right:SetScale(1, 1, 1)
    self.card_right:SetPosition(CARD_W / 2 - SIDE_INSET, 0)

    self.card_banner:SetSize(CARD_W, BANNER_H)
    self.card_banner:SetPosition(0, top - BANNER_H / 2)

    self.card_bottom:SetSize(CARD_W, BANNER_H)
    self.card_bottom:SetPosition(0, -h / 2 + BANNER_H / 2 - BOTTOM_FRAME_DROP)

    -- Title sits in its own band inside the frame. The chevron lives at the
    -- right end of that band, inside the content; the hint button (when the
    -- mission has one) hangs immediately after the rendered title.
    local title_w = COLUMNS.title_w
    local title_cx = COLUMNS.title_cx
    local hint_x = COLUMNS.max_hint_title_w + COLUMNS.left
        + HINT_BUTTON_GAP + HINT_BUTTON_SIZE / 2
    if has_hint then
        -- `title_width` is the measured text width (see SetContent). Clamp it
        -- to the space left by the button so a long title cannot push it into
        -- the chevron; a failed measurement falls back to the full width.
        local measured = title_width ~= nil and title_width > 0
            and math.min(title_width, COLUMNS.max_hint_title_w)
            or COLUMNS.max_hint_title_w
        title_w = measured
        title_cx = COLUMNS.left + measured / 2
        hint_x = COLUMNS.left + measured + HINT_BUTTON_GAP + HINT_BUTTON_SIZE / 2
    end
    local title_y = top - TOP_SAFE - TITLE_H / 2
    self.card_title:SetRegionSize(title_w, TITLE_H)
    self.card_subtext:SetRegionSize(COLUMNS.subtext_w, SUBTEXT_H)
    self.card_title:SetPosition(title_cx, title_y)
    self.card_chevron:SetPosition(COLUMNS.chevron_x, title_y)
    self.card_hint_button:SetPosition(hint_x, title_y)

    self.card_divider:SetSize(COLUMNS.subtext_w, DIVIDER_H)
    self.card_divider:SetPosition(COLUMNS.subtext_cx, -h / 2 + BOTTOM_SAFE + SUBTEXT_H + DIVIDER_GAP + DIVIDER_H / 2)
    self.card_subtext:SetPosition(COLUMNS.subtext_cx, -h / 2 + BOTTOM_SAFE + SUBTEXT_H / 2)

    -- The strip fill stops above the bottom rail, exactly like the card, so
    -- the rail's centre relief falls over the dark world.
    self.strip_hit:SetSize(CARD_W, STRIP_H)
    self.strip_hit:SetPosition(0, 0)
    self.strip_fill:SetSize(CARD_W, STRIP_H - FILL_INSET)
    self.strip_fill:SetPosition(0, FILL_INSET / 2)

    self.strip_clip:SetScissor(-CARD_W / 2, -STRIP_H / 2 + FILL_INSET, CARD_W, STRIP_H - FILL_INSET)
    local strip_side_h = SIDE_W * SIDE_ASPECT
    self.strip_left:SetSize(SIDE_W, strip_side_h)
    self.strip_left:SetScale(-1, 1, 1)
    self.strip_left:SetPosition(-CARD_W / 2 + SIDE_INSET, 0)
    self.strip_right:SetSize(SIDE_W, strip_side_h)
    self.strip_right:SetScale(1, 1, 1)
    self.strip_right:SetPosition(CARD_W / 2 - SIDE_INSET, 0)

    -- The underside banner caps the bottom of the collapsed strip, dropped a
    -- little so its bar sits lower and the corner pieces hang below the edge.
    self.strip_banner:SetSize(CARD_W, BANNER_H)
    self.strip_banner:SetPosition(0, -STRIP_H / 2 + BANNER_H / 2 - BOTTOM_FRAME_DROP)
    local strip_title_y = STRIP_H / 2 - STRIP_TITLE_MARGIN - TITLE_H / 2
    self.strip_title:SetRegionSize(COLUMNS.title_w, TITLE_H)
    self.strip_title:SetPosition(COLUMNS.title_cx, strip_title_y)
    self.strip_chevron:SetPosition(COLUMNS.chevron_x, strip_title_y)
end

function MissionTracker:ApplyExpandedPosition()
    self.transitioning = false
    self.card:CancelMoveTo()
    self.strip:CancelMoveTo()

    if self.expanded then
        self.strip:Hide()
        self.card:Show()
        self.card:SetPosition(self.card_open_pos)
    else
        self.card:Hide()
        self.card:SetPosition(self.card_offscreen_pos)
        self.strip:Show()
        self.strip:SetPosition(self.strip_open_pos)
    end
end

function MissionTracker:SetExpanded(expand)
    if self.transitioning or expand == self.expanded then
        return
    end
    self.expanded = expand

    -- Only one widget moves per transition. Animating the card and the strip
    -- in opposite directions at once read as a bounce, so the strip appears
    -- (or disappears) instantly and the card does all the travelling.
    if expand then
        self.strip:ClearFocus()
        self.strip:CancelMoveTo()
        self.strip:Hide()

        self.card:CancelMoveTo()
        self.card:Show()
        self.card:MoveTo(self.card_offscreen_pos, self.card_open_pos, SLIDE_TIME)
    else
        -- Let the whole card slide up first, then reveal the strip. Only one
        -- widget moves, but the up animation stays visible.
        self.strip:ClearFocus()
        self.strip:CancelMoveTo()

        self.card:ClearFocus()
        self.card:CancelMoveTo()
        self.card:MoveTo(self.card_open_pos, self.card_offscreen_pos, SLIDE_TIME, function()
            self.card:Hide()
            self.strip:Show()
            self.strip:SetPosition(self.strip_open_pos)
        end)
    end
end

-- ------------------------------------------------------------- rendering

function MissionTracker:ParseRows(payload)
    local rows = {}
    if payload == nil or payload == "" then
        return rows
    end

    for _, raw in ipairs(Split(payload, ";")) do
        if raw ~= "" then
            local parts = Split(raw, "|")
            rows[#rows + 1] = {
                -- Source text: translated at render time (BuildRows).
                label = parts[1] or "",
                prefab = parts[2] or "",
                counter = parts[3] or "",
                done = parts[4] == "1",
                -- Appended field; a payload from before optional objectives
                -- simply has no fifth part and reads as required.
                optional = parts[5] == "1",
                -- Appended fields 6-8, present only on survive rows: "day" plus
                -- the current and target day, so this client can format the
                -- counter in its own language. Older servers omit them, and the
                -- pre-formatted `counter` above is used as the fallback.
                counter_kind = parts[6] ~= nil and parts[6] ~= "" and parts[6] or nil,
                counter_current = tonumber(parts[7]),
                counter_target = tonumber(parts[8]),
            }
        end
    end
    return rows
end

-- The counter text for a row. Only the day counter contains a word, so it is
-- rebuilt here from the numbers the server sent; every other counter is a
-- language-neutral "current/target" or percentage string.
function MissionTracker:FormatCounter(row)
    if row.counter_kind == "day"
        and row.counter_current ~= nil and row.counter_target ~= nil then
        return L10n.Lfmt(Strings.DAY_COUNTER_FMT,
            row.counter_current, row.counter_target)
    end
    return row.counter or ""
end

-- Add the icon for a row's id at (x, y). Returns true when one was drawn.
-- Static UI art and world anims win over inventory lookups; the flower anim is
-- scaled to the slot and centred on its visual bounds, because it is authored
-- around the entity's feet rather than its centre.
function MissionTracker:AddRowIcon(prefab, x, y)
    if prefab == nil or prefab == "" then
        return false
    end

    local static = ICON_IMAGES[prefab]
    if static ~= nil then
        local icon = self.row_root:AddChild(Image(static[1], static[2]))
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon:SetPosition(x, y)
        icon:SetClickable(false)
        self.row_widgets[#self.row_widgets + 1] = icon
        return true
    end

    local anim_def = ICON_ANIMS[prefab]
    if anim_def ~= nil then
        local anim = self.row_root:AddChild(UIAnim())
        local state = anim:GetAnimState()
        state:SetBank(anim_def.bank)
        state:SetBuild(anim_def.build)
        state:PlayAnimation(anim_def.animation)

        -- A UIAnim's art is anchored at the top-left of its visual box and
        -- extends right and down from the widget position (the scrapbook
        -- screen centres entity art the same way:
        -- screens/redux/scrapbookscreen.lua:1687-1704). Read the raw box before
        -- scaling, then offset by half the scaled box so the art's centre
        -- lands on the row: x shifts left, y shifts up.
        local x1, y1, x2, y2 = state:GetVisualBB()
        x1, y1, x2, y2 = x1 or 0, y1 or 0, x2 or 0, y2 or 0
        local largest = math.max(x2 - x1, y2 - y1)
        local scale = largest > 0 and ICON_SIZE / largest or 1
        anim:SetScale(scale)

        local cx = (x1 + x2) / 2
        local cy = (y1 + y2) / 2
        anim:SetPosition(x - cx * scale, y + cy * scale)
        anim:SetClickable(false)
        self.row_widgets[#self.row_widgets + 1] = anim
        return true
    end

    local tex = prefab .. ".tex"
    if GetInventoryItemAtlas ~= nil then
        -- The `true` is mandatory: without it the helper falls back to
        -- inventoryimages4 even when the icon does not exist.
        local atlas = GetInventoryItemAtlas(tex, true)
        if atlas ~= nil then
            local icon = self.row_root:AddChild(Image(atlas, tex))
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon:SetPosition(x, y)
            icon:SetClickable(false)
            self.row_widgets[#self.row_widgets + 1] = icon
            return true
        end
    end

    return false
end

function MissionTracker:BuildRows(rows)
    for _, widget in ipairs(self.row_widgets) do
        widget:Kill()
    end
    self.row_widgets = {}

    local top = self.card_h / 2
    -- Rows are stacked from the top; the optional heading (when present) eats
    -- a band between the two groups, pushing every optional row down by it.
    local y_cursor = top - TOP_SAFE - TITLE_H - TITLE_GAP
    local optional_header_drawn = false

    -- Pass 1: the counter, or the check that replaces it. The icon column is
    -- sized from the widest counter so the icons line up down the card instead
    -- of hugging each row's own counter ("0/3" is narrower than "0/15").
    local plans = {}
    local counter_column_w = CHECK_SIZE
    for _, row in ipairs(rows) do
        if row.optional and not optional_header_drawn then
            optional_header_drawn = true
            y_cursor = y_cursor - OPTIONAL_HEADER_H

            local header = self.row_root:AddChild(
                Text(UIFONT, 20, L10n.L(Strings.OPTIONAL), UICOLOURS.HIGHLIGHT_GOLD))
            header:SetRegionSize(COLUMNS.subtext_w, OPTIONAL_HEADER_H)
            header:SetHAlign(ANCHOR_LEFT)
            header:SetVAlign(ANCHOR_MIDDLE)
            header:SetPosition(COLUMNS.subtext_cx, y_cursor + OPTIONAL_HEADER_H / 2)
            header:SetClickable(false)
            self.row_widgets[#self.row_widgets + 1] = header
        end

        local y = y_cursor - ROW_H / 2
        y_cursor = y_cursor - ROW_H

        local counter_w = CHECK_SIZE
        if row.done then
            -- Vanilla DST checkmark. It is dark green in the atlas, so it is
            -- drawn untinted rather than attempt a gold tint that cannot work.
            local check = self.row_root:AddChild(Image(UI_ATLAS, "checkmark.tex"))
            check:SetSize(CHECK_SIZE, CHECK_SIZE)
            check:SetPosition(COLUMNS.check_x, y)
            check:SetClickable(false)
            self.row_widgets[#self.row_widgets + 1] = check
        else
            local counter_colour = row.optional and UICOLOURS.GOLD_UNIMPORTANT
                or UICOLOURS.IVORY
            local counter = self.row_root:AddChild(
                Text(BODYTEXTFONT, 24, self:FormatCounter(row), counter_colour))
            counter:SetVAlign(ANCHOR_MIDDLE)
            counter_w = counter:GetRegionSize()
            counter:SetPosition(COLUMNS.right - counter_w / 2, y)
            counter:SetClickable(false)
            self.row_widgets[#self.row_widgets + 1] = counter
        end

        counter_column_w = math.max(counter_column_w, counter_w)
        plans[#plans + 1] = { row = row, y = y, counter_w = counter_w }
    end

    local icon_x = COLUMNS.right - counter_column_w - ICON_GAP - ICON_SIZE / 2

    -- Pass 2: icons and labels. Labels always start at the content edge; an
    -- icon only takes space from the right of the label, just before the
    -- counter column. Optional rows are dimmed rather than prefixed: the
    -- "Optional" heading above the group carries the meaning.
    for _, plan in ipairs(plans) do
        local row, y, counter_w = plan.row, plan.y, plan.counter_w
        local has_icon = self:AddRowIcon(row.prefab, icon_x, y)

        local label_left = COLUMNS.left
        local label_right = has_icon and (icon_x - ICON_SIZE / 2 - 8)
            or (COLUMNS.right - counter_w - 10)
        local label_w = label_right - label_left
        local colour = row.done and UICOLOURS.IVORY_70
            or (row.optional and UICOLOURS.GOLD_UNIMPORTANT or UICOLOURS.IVORY)
        local label = self.row_root:AddChild(
            Text(UIFONT, 22, L10n.L(row.label), colour))
        label:SetRegionSize(label_w, ROW_H)
        label:SetHAlign(ANCHOR_LEFT)
        label:SetVAlign(ANCHOR_MIDDLE)
        label:SetPosition(label_left + label_w / 2, y)
        label:SetClickable(false)
        self.row_widgets[#self.row_widgets + 1] = label
    end
end

-- Show the "?" and attach the hint to it. The hover text is wrapped here
-- rather than through SetHoverText's region/wordwrap params, because that path
-- sizes the dark backing from the fixed region (always the full width) and the
-- backing must stay inside the HUD. Measuring the wrapped text also lets the
-- tooltip hang at a fixed distance below the button whatever its line count.
function MissionTracker:SetHint(hint)
    local button = self.card_hint_button

    if hint == nil or hint == "" then
        -- ClearFocus first: hiding a focused widget would otherwise leave its
        -- tooltip root on screen.
        button:ClearFocus()
        button:ClearHoverText()
        button:Hide()
        return
    end

    button:Show()

    if self.hint_params == nil then
        -- One table, reused: SetHoverText's focus handler closes over it, so
        -- updating offset_y here also moves the tooltip for later hints.
        self.hint_params = {
            font = NEWFONT_OUTLINE,
            font_size = HINT_TOOLTIP_FONT_SIZE,
            colour = { 1, 1, 1, 1 },
            attach_to_parent = self.card,
            offset_y = -HINT_BUTTON_SIZE / 2 - HINT_TOOLTIP_GAP,
        }
    end

    button:SetHoverText(hint, self.hint_params)

    -- SetHoverText created or updated `button.hovertext`; rewrap it in place.
    local text = button.hovertext
    local bg = button.hovertext_bg
    if text == nil then
        return
    end

    -- Measure one line's height before wrapping: GetRegionSize() does not
    -- reliably report the height of a string with embedded newlines, so the
    -- backing must be sized from the line count instead. (spirequal_outline is
    -- a 50px BMFont whose lineHeight is 50, so one line is ~font_size px.)
    local _, line_h = text:GetRegionSize()
    if line_h == nil or line_h <= 0 then
        line_h = HINT_TOOLTIP_FONT_SIZE
    end

    local lines = text:SetMultilineTruncatedString(
        hint, HINT_TOOLTIP_MAX_LINES, HINT_TOOLTIP_W, nil, true)
    lines = math.max(lines or 1, 1)

    if bg ~= nil then
        local w = text:GetRegionSize()
        -- A stale/unsplit width would be the whole hint; cap it at the wrap
        -- width so the backing never exceeds the card.
        if w == nil or w <= 0 or w > HINT_TOOLTIP_W then
            w = HINT_TOOLTIP_W
        end
        -- SetHoverText draws the text at 1.1x scale, so both the width and the
        -- height must account for it. The height adds a fixed margin above and
        -- below the text: a multiplier gives a one-line hint almost no padding.
        local bg_w = w * 1.25
        local bg_h = line_h * lines * 1.1 + HINT_TOOLTIP_PAD * 2
        bg:SetSize(bg_w, bg_h)
        self.hint_params.offset_y =
            -(HINT_BUTTON_SIZE / 2 + HINT_TOOLTIP_GAP + bg_h / 2)
    end
end

function MissionTracker:SetContent(state, rows)
    -- The server sends source text; translate here, before measuring the title
    -- and wrapping the hint, so the layout fits this client's language.
    local title = L10n.L(state.title)
    local subtext = L10n.L(state.subtext)
    local hint = L10n.L(state.hint)
    local emergency = state.state == "emergency"

    -- An emergency borrows the same card but tints the title red, so the pop-up
    -- reads differently from a normal mission at a glance. The divider stays
    -- the normal brown.
    local title_colour = emergency and UICOLOURS.RED or UICOLOURS.HIGHLIGHT_GOLD
    self.card_title:SetColour(title_colour)
    self.strip_title:SetColour(title_colour)
    self.card_divider:SetTint(unpack(BROWN))

    -- The "?" sits immediately after the title, so measure the rendered title
    -- first. ResetRegionSize makes GetRegionSize return the text extent rather
    -- than the previous layout's region; Layout sets the region again.
    self.card_title:SetString(title)
    self.card_title:ResetRegionSize()
    local title_width = self.card_title:GetRegionSize()

    local has_optional = false
    for _, row in ipairs(rows) do
        if row.optional then
            has_optional = true
            break
        end
    end

    self:Layout(#rows, hint ~= "", title_width, has_optional)
    self.strip_title:SetString(title)
    self.card_subtext:SetString(subtext)
    self:SetHint(hint)
    self:BuildRows(rows)
end

-- -------------------------------------------------------------- states

function MissionTracker:PlaySting()
    if TheFrontEnd ~= nil and TheFrontEnd.GetSound ~= nil then
        local sound = TheFrontEnd:GetSound()
        if sound ~= nil then
            sound:PlaySound(STING_EVENT, nil, STING_VOLUME)
        end
    end
end

function MissionTracker:CancelHideTask()
    if self.hide_task ~= nil then
        self.hide_task:Cancel()
        self.hide_task = nil
    end
end

function MissionTracker:ScheduleHide(delay)
    self:CancelHideTask()
    self.hide_task = self.inst:DoTaskInTime(delay, function()
        self.hide_task = nil
        if not self.inst:IsValid() then
            return
        end
        self.card:ClearFocus()
        self.strip:ClearFocus()
        self:Hide()
    end)
end

-- Slide the card up out of view, swap in the next payload, slide back down.
-- The card must already be at its open position when this starts.
function MissionTracker:Transition(swap)
    local was_collapsed = not self.expanded
    self.transitioning = true
    self.expanded = true

    -- A new mission always expands the card.
    self.strip:ClearFocus()
    self.strip:CancelMoveTo()
    self.strip:Hide()

    self.card:ClearFocus()
    self.card:CancelMoveTo()
    self.card:Show()

    if was_collapsed then
        self.card:SetPosition(self.card_offscreen_pos)
        swap()
        self.card:MoveTo(self.card_offscreen_pos, self.card_open_pos, SLIDE_TIME, function()
            self.transitioning = false
            -- The slide captured its target vector before swap() ran; resync
            -- in case the player dragged during the transition.
            self:ApplyDockX()
        end)
    else
        self.card:MoveTo(self.card_open_pos, self.card_offscreen_pos, SLIDE_TIME, function()
            swap()
            self.card:MoveTo(self.card_offscreen_pos, self.card_open_pos, SLIDE_TIME, function()
                self.transitioning = false
                self:ApplyDockX()
            end)
        end)
    end
end

-- The four fields share one dirty event, so a single server write can produce
-- several callbacks with the same payload. Only the first should animate.
local function SamePayload(a, b)
    return a ~= nil
        and b ~= nil
        and a.title == b.title
        and a.subtext == b.subtext
        and a.hint == b.hint
        and a.rows == b.rows
        and a.state == b.state
end

function MissionTracker:Refresh()
    if not self.inst:IsValid() or self.owner == nil or not self.owner:IsValid() then
        return
    end

    local state = Netvars.Read(self.owner)
    if state.title == nil or state.title == "" then
        self:CancelHideTask()
        self.last_state = nil
        self.last_payload = nil
        self:Hide()
        return
    end

    if SamePayload(self.last_payload, state) then
        return
    end
    self.last_payload = {
        title = state.title,
        subtext = state.subtext,
        hint = state.hint,
        rows = state.rows,
        state = state.state,
    }

    local rows = self:ParseRows(state.rows)
    local previous = self.last_state
    local new_state = state.state

    self.last_state = new_state
    self:CancelHideTask()
    self:Show()

    if new_state == "done" then
        if previous ~= "done" then
            self:PlaySting()
        end
        if previous == "won" then
            self:Transition(function()
                self:SetContent(state, rows)
            end)
        else
            self:SetContent(state, rows)
            self:ApplyExpandedPosition()
        end
        self:ScheduleHide(DONE_HIDE_DELAY)
        return
    end

    -- "emergency": a pop-up replacing the chain card. The first appearance (or
    -- a return from a chain mission) force-opens the card and slides it in;
    -- objective progress after that renders in place.
    if new_state == "emergency" then
        if previous == "emergency" then
            self:SetContent(state, rows)
            self:ApplyExpandedPosition()
        else
            self:Transition(function()
                self:SetContent(state, rows)
            end)
        end
        return
    end

    if new_state == "won" then
        -- A recovered emergency must be visible even if the tracker was
        -- collapsed when the emergency started.
        if previous == "emergency" then
            self.expanded = true
        end
        if previous ~= "won" then
            self:PlaySting()
        end
        self:SetContent(state, rows)
        self:ApplyExpandedPosition()
        return
    end

    -- "active": a mission in progress. A payload arriving straight after a
    -- completion, or after an emergency resolves, is the next/restored mission,
    -- so slide the old card away and the new one in. Anything else renders in
    -- place.
    if previous == "won" or previous == "emergency" then
        self:Transition(function()
            self:SetContent(state, rows)
        end)
    else
        self:SetContent(state, rows)
        self:ApplyExpandedPosition()
    end
end

return MissionTracker
