-- Client HUD for the guided mission chain.
--
-- Pure renderer: the server writes the four netvar strings (title, subtext,
-- rows, state) and this widget only draws them. It never sends progress back
-- and never changes game state.
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

local CRAFTING_ATLAS = "images/crafting_menu.xml"
local UI_ATLAS = "images/ui.xml"

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
local DEFAULT_RIGHT_MARGIN = 190  -- used when the status display cannot be read
local STATUS_GAP = 20             -- gap between the card and the nearest badge
local BADGE_HALF_W = 48           -- half the width of a status badge
local MARGIN_TOP = 4
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
    return {
        left = left,
        right = right,
        chevron_x = chevron_x,
        check_x = right - CHECK_SIZE / 2,
        title_w = title_w,
        title_cx = left + title_w / 2,
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

    self.card = self:AddChild(Widget("guidedmission_card"))

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

    local scale = parent:GetWorldScale().x
    if scale == nil or scale == 0 then
        scale = 1
    end

    local margin = (parent:GetWorldPosition().x - left) / scale + BADGE_HALF_W + STATUS_GAP

    -- Never let a strange HUD push the card off the screen or over the badges.
    return math.max(margin, CARD_W / 2 + 8)
end

function MissionTracker:Layout(row_count)
    local h = CARD_BASE_H + ROW_H * row_count
    self.card_h = h
    local margin = self:MeasureRightMargin()

    self.card_open_pos = Vector3(-(margin + CARD_W / 2), -(MARGIN_TOP + h / 2), 0)
    self.card_offscreen_pos = self.card_open_pos + Vector3(0, MARGIN_TOP + h + STEP_OFFSCREEN_Y, 0)
    self.strip_open_pos = Vector3(-(margin + CARD_W / 2), -(STRIP_MARGIN_TOP + STRIP_H / 2), 0)

    local top = h / 2

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
    -- right end of that band, inside the content.
    self.card_title:SetRegionSize(COLUMNS.title_w, TITLE_H)
    self.card_subtext:SetRegionSize(COLUMNS.subtext_w, SUBTEXT_H)
    self.card_title:SetPosition(COLUMNS.title_cx, top - TOP_SAFE - TITLE_H / 2)
    self.card_chevron:SetPosition(COLUMNS.chevron_x, top - TOP_SAFE - TITLE_H / 2)

    self.card_divider:SetSize(COLUMNS.subtext_w, DIVIDER_H)
    self.card_divider:SetPosition(COLUMNS.subtext_cx, -h / 2 + BOTTOM_SAFE + SUBTEXT_H + DIVIDER_GAP + DIVIDER_H / 2)
    self.card_subtext:SetPosition(COLUMNS.subtext_cx, -h / 2 + BOTTOM_SAFE + SUBTEXT_H / 2)

    -- The strip fill stops above the bottom rail, exactly like the card, so
    -- the rail's centre relief falls over the dark world.
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
                label = parts[1] or "",
                prefab = parts[2] or "",
                counter = parts[3] or "",
                done = parts[4] == "1",
            }
        end
    end
    return rows
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

    -- Pass 1: the counter, or the check that replaces it. The icon column is
    -- sized from the widest counter so the icons line up down the card instead
    -- of hugging each row's own counter ("0/3" is narrower than "0/15").
    local plans = {}
    local counter_column_w = CHECK_SIZE
    for i, row in ipairs(rows) do
        local y = top - TOP_SAFE - TITLE_H - TITLE_GAP - ROW_H * (i - 0.5)

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
            local counter = self.row_root:AddChild(Text(BODYTEXTFONT, 24, row.counter, UICOLOURS.IVORY))
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
    -- counter column.
    for _, plan in ipairs(plans) do
        local row, y, counter_w = plan.row, plan.y, plan.counter_w
        local has_icon = self:AddRowIcon(row.prefab, icon_x, y)

        local label_left = COLUMNS.left
        local label_right = has_icon and (icon_x - ICON_SIZE / 2 - 8)
            or (COLUMNS.right - counter_w - 10)
        local label_w = label_right - label_left
        local colour = row.done and UICOLOURS.IVORY_70 or UICOLOURS.IVORY
        local label = self.row_root:AddChild(Text(UIFONT, 22, row.label, colour))
        label:SetRegionSize(label_w, ROW_H)
        label:SetHAlign(ANCHOR_LEFT)
        label:SetVAlign(ANCHOR_MIDDLE)
        label:SetPosition(label_left + label_w / 2, y)
        label:SetClickable(false)
        self.row_widgets[#self.row_widgets + 1] = label
    end
end

function MissionTracker:SetContent(state, rows)
    self:Layout(#rows)
    self.card_title:SetString(state.title)
    self.strip_title:SetString(state.title)
    self.card_subtext:SetString(state.subtext or "")
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
        end)
    else
        self.card:MoveTo(self.card_open_pos, self.card_offscreen_pos, SLIDE_TIME, function()
            swap()
            self.card:MoveTo(self.card_offscreen_pos, self.card_open_pos, SLIDE_TIME, function()
                self.transitioning = false
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

    if new_state == "won" then
        if previous ~= "won" then
            self:PlaySting()
        end
        self:SetContent(state, rows)
        self:ApplyExpandedPosition()
        return
    end

    -- "active": a mission in progress. A payload arriving straight after a
    -- completion is the next mission, so slide the old card away and the new
    -- one in. Anything else renders in place.
    if previous == "won" then
        self:Transition(function()
            self:SetContent(state, rows)
        end)
    else
        self:SetContent(state, rows)
        self:ApplyExpandedPosition()
    end
end

return MissionTracker
