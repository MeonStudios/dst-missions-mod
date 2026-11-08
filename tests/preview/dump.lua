-- Runs the real guidedmissiontracker widget with stubbed DST classes and
-- dumps its widget tree (positions, textures, text, colours) as JSON for
-- render.py. This keeps the preview in sync with the actual layout code.
--
--   lua tests/preview/dump.lua            (see run.sh for the full pipeline)

local script_path = arg and arg[0] or "tests/preview/dump.lua"
local here = script_path:match("^(.*)[/\\][^/\\]+$") or "."
local mod_root = here .. "/../.."
package.path = mod_root .. "/scripts/?.lua;" .. package.path

-- ---- minimal DST environment ---------------------------------------------

function Class(base, ctor)
    if ctor == nil then
        ctor = base
        base = nil
    end
    local cls = {}
    cls.__index = cls
    cls._ctor = ctor
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

local vector_mt = {}

function Vector3(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vector_mt)
end

vector_mt.__add = function(a, b)
    return Vector3(a.x + b.x, a.y + b.y, a.z + b.z)
end

ANCHOR_MIDDLE, ANCHOR_LEFT, ANCHOR_RIGHT = 0, 1, 2
ANCHOR_TOP, ANCHOR_BOTTOM = 1, 2
SCALEMODE_PROPORTIONAL = 2
MAX_HUD_SCALE = 1.25

UIFONT = "belisaplumilla50"
BODYTEXTFONT = "stint-ucr50"

local function rgb(r, g, b)
    return { r / 255, g / 255, b / 255, 1 }
end

UICOLOURS = {
    HIGHLIGHT_GOLD = rgb(243, 217, 161),
    IVORY = rgb(236, 232, 223),
    IVORY_70 = rgb(165, 162, 156),
}

BROWN = { 97 / 255, 73 / 255, 46 / 255, 1 }

-- Icon atlases verified in docs/dst-api.md.
local ITEM_ATLAS = {
    flint = "images/inventoryimages2.xml",
    log = "images/inventoryimages2.xml",
    firepit = "images/inventoryimages2.xml",
    goldnugget = "images/inventoryimages2.xml",
    twigs = "images/inventoryimages3.xml",
    torch = "images/inventoryimages3.xml",
    spider = "images/inventoryimages3.xml",
    researchlab = "images/inventoryimages3.xml",
}

function GetInventoryItemAtlas(tex)
    local prefab = tex:gsub("%.tex$", "")
    return ITEM_ATLAS[prefab]
end

-- ---- widget stubs --------------------------------------------------------

local Widget = Class(function(self, name)
    self.kind = "Widget"
    self.name = name or "widget"
    self.children = {}
    self.x, self.y = 0, 0
    self.sx, self.sy = 1, 1
    self.shown = true
    self.scissor = nil
    self.inst = {
        IsValid = function() return true end,
        DoTaskInTime = function()
            return { Cancel = function() end }
        end,
    }
end)

function Widget:AddChild(child)
    child.parent = self
    self.children[#self.children + 1] = child
    return child
end

function Widget:SetPosition(x, y, z)
    if type(x) == "number" then
        self.x, self.y = x, y or 0
    else
        self.x, self.y = x.x, x.y
    end
end

function Widget:SetScale(x, y, z)
    if type(x) == "number" then
        self.sx = x
        self.sy = y or x
    else
        self.sx, self.sy = x.x, x.y
    end
end

function Widget:SetRotation(angle)
    self.rotation = angle or 0
end

function Widget:GetScale()
    return Vector3(self.sx, self.sy, 1)
end

function Widget:GetWorldScale()
    return Vector3(self.sx, self.sy, 1)
end

function Widget:GetParent()
    return self.parent
end

function Widget:GetChildren()
    return self.children
end

function Widget:GetWorldPosition()
    return Vector3(self.x, self.y, 0)
end

function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:SetClickable() end
function Widget:SetHAnchor() end
function Widget:SetVAnchor() end
function Widget:SetScaleMode() end
function Widget:SetMaxPropUpscale() end
function Widget:SetHRegPoint() end
function Widget:SetVRegPoint() end
function Widget:SetScissor(x, y, w, h) self.scissor = { x = x, y = y, w = w, h = h } end
function Widget:SetFadeAlpha() end
function Widget:ClearFocus() end
function Widget:SetFocus() end
function Widget:Enable() end
function Widget:Disable() end
function Widget:IsEnabled() return true end
function Widget:CancelMoveTo() end
function Widget:CancelScaleTo() end
function Widget:CancelTintTo() end

function Widget:MoveTo(from, to)
    self:SetPosition(to)
    self.shown = true
end

function Widget:IsVisible()
    return self.shown and (self.parent == nil or self.parent:IsVisible())
end

function Widget:Kill()
    if self.parent then
        for i, c in ipairs(self.parent.children) do
            if c == self then
                table.remove(self.parent.children, i)
                break
            end
        end
        self.parent = nil
    end
end

local Image = Class(Widget, function(self, atlas, tex)
    Widget._ctor(self, "Image")
    self.kind = "Image"
    self.atlas = atlas
    self.tex = tex
    self.w, self.h = 0, 0
    self.tint = { 1, 1, 1, 1 }
end)

function Image:SetTexture(atlas, tex)
    self.atlas, self.tex = atlas, tex
end

function Image:SetSize(w, h)
    if type(w) == "number" then
        self.w, self.h = w, h or w
    else
        self.w, self.h = w[1], w[2]
    end
end

function Image:ScaleToSize(w, h)
    self.w, self.h = math.abs(w), math.abs(h)
    if w < 0 then self.sx = -1 end
    if h < 0 then self.sy = -1 end
end

function Image:SetTint(r, g, b, a)
    self.tint = { r, g, b, a }
end

function Image:SetMouseOverTexture() end
function Image:SetDisabledTexture() end

local Text = Class(Widget, function(self, font, size, string, colour)
    Widget._ctor(self, "Text")
    self.kind = "Text"
    self.font = font
    self.size = size
    self.string = string or ""
    self.colour = colour or { 1, 1, 1, 1 }
    self.halign = ANCHOR_MIDDLE
    self.valign = ANCHOR_MIDDLE
    self.region_w, self.region_h = nil, nil
end)

function Text:SetString(s) self.string = s or "" end
function Text:SetColour(r, g, b, a)
    if type(r) == "number" then
        self.colour = { r, g, b, a }
    else
        self.colour = r
    end
end
function Text:SetHAlign(a) self.halign = a end
function Text:SetVAlign(a) self.valign = a end
function Text:SetRegionSize(w, h) self.region_w, self.region_h = w, h end
function Text:SetFont(f) self.font = f end
function Text:SetSize(s) self.size = s end

-- Width lookup for the counter font (stint-ucr50), so the preview reproduces
-- the runtime GetRegionSize() the tracker uses to place icons against counters.
local STINT_ADVANCE = {
    [32] = 8, [47] = 11, [48] = 16, [49] = 11, [50] = 14, [51] = 14,
    [52] = 15, [53] = 14, [54] = 15, [55] = 13, [56] = 15, [57] = 15,
    [68] = 18, [97] = 13, [121] = 14,
}

function Text:GetRegionSize()
    if self.region_w ~= nil then
        return self.region_w, self.region_h
    end
    local total = 0
    if self.font == BODYTEXTFONT then
        for i = 1, #self.string do
            total = total + (STINT_ADVANCE[self.string:byte(i)] or 20)
        end
        total = total * self.size / 50
    else
        total = #self.string * self.size * 0.5
    end
    return total, self.size
end

local ImageButton = Class(Widget, function(self, atlas, normal, focus, disabled, down, selected, scale, offset)
    Widget._ctor(self, "ImageButton")
    self.kind = "ImageButton"
    self.image = self:AddChild(Image(atlas, normal))
    self.image.w, self.image.h = 63, 63
end)

function ImageButton:ForceImageSize(w, h) self.image:SetSize(w, h) end
function ImageButton:SetOnClick(fn) self.onclick = fn end
function ImageButton:SetNormalScale() end
function ImageButton:SetFocusScale() end
function ImageButton:SetTextures(atlas, normal)
    self.image:SetTexture(atlas, normal)
end

-- Provide the classes the tracker requires under their DST module names.
package.loaded["widgets/widget"] = Widget
package.loaded["widgets/image"] = Image
package.loaded["widgets/text"] = Text
package.loaded["widgets/imagebutton"] = ImageButton

-- The tracker draws the flower row with a UIAnim (the world flower's anim
-- art, which has no readable static texture). render.py cannot decode engine
-- animations, so a UIAnim row is laid out but not painted in the preview; see
-- docs/dst-api.md, "Item icons and UI atlases".
local UIAnim = Class(Widget, function(self)
    Widget._ctor(self, "UIAnim")
    self.anim_state = {
        SetBank = function(state, value) state.bank = value end,
        SetBuild = function(state, value) state.build = value end,
        PlayAnimation = function(state, value) state.animation = value end,
        -- Top-left anchored box, as the engine reports it.
        GetVisualBB = function() return 0, 0, 24, 24 end,
    }
end)

function UIAnim:GetAnimState()
    return self.anim_state
end

function UIAnim:GetBoundingBoxSize()
    return 24, 24
end

function UIAnim:GetVisualBB()
    return 0, 0, 24, 24
end

package.loaded["widgets/uianim"] = UIAnim

-- The tracker reads these from the owner's netvars; swap in a table we can
-- replace per scenario.
local current_state = {}
package.loaded["guidedmissions/netvars"] = {
    DIRTY_EVENT = "guidedmissionpreview",
    Read = function()
        return current_state
    end,
}

local sound = { PlaySound = function() end }
TheFrontEnd = { GetSound = function() return sound end }

local owner = {
    IsValid = function() return true end,
    ListenForEvent = function() end,
}

local MissionTracker = require("widgets/guidedmissiontracker")

-- ---- dump ----------------------------------------------------------------

local function escape(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return '"' .. s .. '"'
end

local function num(n)
    return string.format("%.3f", n or 0)
end

local function serialize(node)
    local parts = {
        "\"kind\":" .. escape(node.kind or "Widget"),
        "\"name\":" .. escape(node.name or ""),
        "\"x\":" .. num(node.x),
        "\"y\":" .. num(node.y),
        "\"sx\":" .. num(node.sx or 1),
        "\"sy\":" .. num(node.sy or 1),
        "\"rot\":" .. num(node.rotation or 0),
        "\"shown\":" .. tostring(node.shown and true or false),
    }

    if node.scissor then
        parts[#parts + 1] = string.format(
            '"scissor":[%s,%s,%s,%s]',
            num(node.scissor.x), num(node.scissor.y), num(node.scissor.w), num(node.scissor.h)
        )
    end

    if node.kind == "Image" then
        parts[#parts + 1] = '"atlas":' .. (node.atlas and escape(node.atlas) or "null")
        parts[#parts + 1] = '"tex":' .. (node.tex and escape(node.tex) or "null")
        parts[#parts + 1] = '"w":' .. num(node.w) .. ',"h":' .. num(node.h)
        parts[#parts + 1] = string.format(
            '"tint":[%s,%s,%s,%s]',
            num(node.tint[1]), num(node.tint[2]), num(node.tint[3]), num(node.tint[4])
        )
    elseif node.kind == "Text" then
        parts[#parts + 1] = '"font":' .. escape(node.font)
        parts[#parts + 1] = '"size":' .. num(node.size)
        parts[#parts + 1] = '"string":' .. escape(node.string)
        parts[#parts + 1] = string.format(
            '"colour":[%s,%s,%s,%s]',
            num(node.colour[1]), num(node.colour[2]), num(node.colour[3]), num(node.colour[4] or 1)
        )
        parts[#parts + 1] = '"halign":' .. tostring(node.halign) .. ',"valign":' .. tostring(node.valign)
        parts[#parts + 1] = '"region_w":' .. (node.region_w and num(node.region_w) or "null")
        parts[#parts + 1] = '"region_h":' .. (node.region_h and num(node.region_h) or "null")
    end

    local children = {}
    for _, child in ipairs(node.children or {}) do
        children[#children + 1] = serialize(child)
    end
    parts[#parts + 1] = '"children":[' .. table.concat(children, ",") .. ']'
    return "{" .. table.concat(parts, ",") .. "}"
end

local function build_scenario(name, state, collapse)
    current_state = state
    local tracker = MissionTracker(owner)
    -- In game this widget is docked to the top-right HUD root, so its x is
    -- negative; shift it into the preview canvas.
    tracker:SetPosition(900, 0)
    if collapse then
        tracker.expanded = false
        tracker:ApplyExpandedPosition()
    end
    return "{\"name\":" .. escape(name) .. ",\"tree\":" .. serialize(tracker) .. "}"
end

local ROW = function(label, prefab, counter, done)
    return table.concat({ label, prefab or "", counter, done and "1" or "0" }, "|")
end

-- Same payloads, rendered once per border style so the two frames can be
-- compared side by side.
local CASES = {
    {
        "active_2row",
        {
            title = "Basic Supplies",
            subtext = "Rock. Stick. Civilisation, basically.",
            rows = table.concat({ ROW("Collect flint", "flint", "1/3"), ROW("Collect twigs", "twigs", "0/2") }, ";"),
            state = "active",
        },
    },
    {
        "active_1row",
        {
            title = "See the Dawn",
            subtext = "Just don't stare at the fire all night.",
            rows = ROW("Survive until day 3", "", "Day 1/3"),
            state = "active",
        },
    },
    {
        "sanity_2row",
        {
            title = "Keeping Your Sanity",
            subtext = "The world is strange enough already.",
            rows = table.concat({
                ROW("Pick flowers", "flower", "0/3"),
                ROW("Restore sanity", "brain", "0/15"),
            }, ";"),
            state = "active",
        },
    },
    {
        "won",
        {
            title = "See the Dawn",
            subtext = "Just don't stare at the fire all night.",
            rows = ROW("Survive until day 3", "", "Day 3/3", true),
            state = "won",
        },
    },
    {
        "done",
        {
            title = "All Missions Complete",
            subtext = "You survived. For now.",
            rows = "",
            state = "done",
        },
    },
    {
        "collapsed",
        {
            title = "Basic Supplies",
            subtext = "Rock. Stick. Civilisation, basically.",
            rows = table.concat({ ROW("Collect flint", "flint", "1/3"), ROW("Collect twigs", "twigs", "0/2") }, ";"),
            state = "active",
        },
        true,
    },
}

local scenarios = {}
for _, case in ipairs(CASES) do
    scenarios[#scenarios + 1] = build_scenario(case[1], case[2], case[3])
end

local out = "{\"scenarios\":[" .. table.concat(scenarios, ",") .. "]}"

local out_path = here .. "/out.json"
local fh = assert(io.open(out_path, "w"))
fh:write(out)
fh:close()
print("wrote " .. out_path)
