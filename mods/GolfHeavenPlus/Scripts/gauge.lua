-- Putt gauge: a power bar in the golf HUD, styled like the game's scorecard (light rounded panel,
-- dark green outline, orange header, the game's rounded font). While the putter is drawn back it
-- fills from the bottom and shows the distance the backswing asks for; a blue marker holds the last
-- putt, so the same putt can be played again by pulling back to the marker.
local Golf = require("golf")
local Putt = require("putt")
local Loop = require("loop")

local Gauge = {}

local NAME = "GHP_PuttGauge"
local FRAMES_PER_UPDATE = 2
local WIDTH, HEIGHT = 150, 470
local TRACK = { x = 80, y = 118, w = 30, h = 326 } -- the bar, in panel units
local INSET = 4                                      -- fill inset inside the track
local TICKS = { 1, 2, 3, 5, 10, 20 }                 -- metres marked beside the bar
local EDGE_OFFSET = { right = 90, up = 40 }          -- from the screen's right edge, centre height

-- The scorecard's palette (linear colours read from its widgets).
local ORANGE = { R = 0.807, G = 0.347, B = 0.102, A = 1 }
local BLUE = { R = 0.235, G = 0.565, B = 0.847, A = 1 }
local PANEL = { R = 0.85, G = 0.86, B = 0.86, A = 1 }
local OUTLINE = { R = 0.14, G = 0.46, B = 0.31, A = 1 }
local TRACK_FILL = { R = 0.62, G = 0.66, B = 0.66, A = 1 }
local DARK = { R = 0.082, G = 0.082, B = 0.082, A = 1 }
local WHITE = { R = 0.982, G = 0.982, B = 0.982, A = 1 }
local SHADOW = { R = 0, G = 0, B = 0, A = 0.35 }

local VISIBLE_NO_HIT = 3 -- ESlateVisibility::HitTestInvisible (drawn, never takes clicks)
local COLLAPSED = 1
local HALIGN_RIGHT, VALIGN_CENTER = 3, 2
local JUSTIFY_CENTER, JUSTIFY_RIGHT = 1, 2
local ROUNDED_BOX = 4 -- ESlateBrushDrawType::RoundedBox

local enabled = function() return true end
local ui = nil -- the built widgets, for the HUD they live in
local counter = 0

local function valid(object) return object ~= nil and object:IsValid() end

local function construct(class, outer, name)
    counter = counter + 1
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. class), outer, FName(string.format("%s_%s_%d", NAME, name, counter)))
end

local function slate(color) return { SpecifiedColor = color, ColorUseRule = 0 } end

local function roundedBrush(fill, line, lineWidth, radius)
    return {
        ImageSize = { X = 32, Y = 32 },
        DrawAs = ROUNDED_BOX,
        TintColor = slate(fill),
        OutlineSettings = {
            CornerRadii = { X = radius, Y = radius, Z = radius, W = radius },
            Color = slate(line),
            Width = lineWidth,
            RoundingType = 0,
        },
    }
end

-- The game's club-panel font at another size.
local function font(template, size)
    local f = template.Font
    return {
        FontObject = f.FontObject,
        TypefaceFontName = f.TypefaceFontName,
        Size = size,
        LetterSpacing = f.LetterSpacing,
    }
end

-- Places `widget` in the panel's canvas at x, y with size w, h.
local function place(canvas, widget, x, y, w, h)
    local slot = canvas:AddChildToCanvas(widget)
    slot:SetAutoSize(false)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
    return slot
end

local function box(canvas, tree, name, fill, line, lineWidth, radius, x, y, w, h)
    local image = construct("Image", tree, name)
    image:SetBrush(roundedBrush(fill, line, lineWidth, radius))
    return image, place(canvas, image, x, y, w, h)
end

local function label(canvas, tree, name, template, size, color, justify, x, y, w, h, text)
    local block = construct("TextBlock", tree, name)
    block:SetFont(font(template, size))
    block:SetColorAndOpacity(slate(color))
    block:SetJustification(justify)
    block:SetText(FText(text))
    return block, place(canvas, block, x, y, w, h)
end

-- y of a backswing depth on the track (0 at the bottom, 1 at the top), in panel units.
function Gauge.depthY(depth)
    return TRACK.y + TRACK.h - INSET - (TRACK.h - 2 * INSET) * math.max(0, math.min(1, depth))
end

-- Removes widgets a previous copy of the mod left in this HUD (UE4SS has no unload callback).
local function removeLeftovers(root)
    for i = root:GetChildrenCount() - 1, 0, -1 do
        local child = root:GetChildAt(i)
        if valid(child) and child:GetFName():ToString():find("^" .. NAME) then child:RemoveFromParent() end
    end
end

local function build(hud)
    local tree = hud.WidgetTree
    local root = tree.RootWidget
    removeLeftovers(root)
    local template = hud.WG_GolfClubInfo.CurrentClubName

    local size = construct("SizeBox", tree, "Size")
    size:SetWidthOverride(WIDTH)
    size:SetHeightOverride(HEIGHT)
    local slot = root:AddChildToOverlay(size)
    slot:SetHorizontalAlignment(HALIGN_RIGHT)
    slot:SetVerticalAlignment(VALIGN_CENTER)
    slot:SetPadding({ Left = 0, Top = 0, Right = EDGE_OFFSET.right, Bottom = EDGE_OFFSET.up * 2 })
    local canvas = construct("CanvasPanel", tree, "Canvas")
    size:AddChild(canvas)

    box(canvas, tree, "Frame", PANEL, OUTLINE, 6, 14, 0, 0, WIDTH, HEIGHT)
    box(canvas, tree, "Header", ORANGE, ORANGE, 0, 9, 9, 9, WIDTH - 18, 44)
    local title = label(canvas, tree, "Title", template, 24, WHITE, JUSTIFY_CENTER, 9, 13, WIDTH - 18, 40, "PUTT")
    title:SetShadowOffset({ X = 1.5, Y = 1.5 })
    title:SetShadowColorAndOpacity(SHADOW)
    local distance = label(canvas, tree, "Distance", template, 30, DARK, JUSTIFY_CENTER, 6, 60, WIDTH - 12, 48, "0.0 m")

    box(canvas, tree, "Track", TRACK_FILL, OUTLINE, 3, 15, TRACK.x, TRACK.y, TRACK.w, TRACK.h)
    local fill, fillSlot = box(canvas, tree, "Fill", ORANGE, ORANGE, 0, 11,
        TRACK.x + INSET, Gauge.depthY(0), TRACK.w - 2 * INSET, 0)
    for _, metres in ipairs(TICKS) do
        local y = Gauge.depthY(Putt.depthFor(metres * 100))
        box(canvas, tree, "Tick", DARK, DARK, 0, 1, TRACK.x - 12, y - 1.5, 9, 3)
        label(canvas, tree, "TickLabel", template, 16, DARK, JUSTIFY_RIGHT, 4, y - 11, TRACK.x - 20, 22, metres .. " m")
    end
    local marker, markerSlot = box(canvas, tree, "Last", BLUE, WHITE, 2, 6, TRACK.x - 6, Gauge.depthY(0) - 6, TRACK.w + 12, 12)
    marker:SetVisibility(COLLAPSED)

    ui = {
        hud = hud, root = size, distance = distance, fillSlot = fillSlot, marker = marker, markerSlot = markerSlot,
        shown = nil, depth = nil, text = nil, last = false,
    }
    size:SetVisibility(COLLAPSED)
end

local function show(visible)
    if ui.shown == visible then return end
    ui.shown = visible
    ui.root:SetVisibility(visible and VISIBLE_NO_HIT or COLLAPSED)
end

function Gauge.update()
    local controller = Golf.localController()
    local pawn = valid(controller) and controller.Pawn or nil
    local club = valid(pawn) and Golf.heldClub(pawn) or nil
    local putting = club ~= nil and Golf.isPutter(club) and enabled()
    if not putting then
        if ui ~= nil and valid(ui.root) then show(false) end
        return
    end
    local hud = club.CachedGolfHUD
    if not valid(hud) then return end
    if ui == nil or not valid(ui.root) or ui.hud:GetAddress() ~= hud:GetAddress() then build(hud) end

    local status = Putt.status()
    show(true)
    if status.depth ~= ui.depth then
        ui.depth = status.depth
        local top = Gauge.depthY(status.depth)
        ui.fillSlot:SetPosition({ X = TRACK.x + INSET, Y = top })
        ui.fillSlot:SetSize({ X = TRACK.w - 2 * INSET, Y = Gauge.depthY(0) - top })
    end
    local text = status.live and string.format("%.1f m", status.distance / 100)
        or (status.last and string.format("%.1f m", status.last / 100)) or "0.0 m"
    if text ~= ui.text then
        ui.text = text
        ui.distance:SetText(FText(text))
    end
    if status.last ~= ui.last then
        ui.last = status.last
        if status.last then
            ui.markerSlot:SetPosition({ X = TRACK.x - 6, Y = Gauge.depthY(Putt.depthFor(status.last)) - 6 })
            ui.marker:SetVisibility(VISIBLE_NO_HIT)
        else
            ui.marker:SetVisibility(COLLAPSED)
        end
    end
end

-- isEnabled: function returning whether backswing putting (Real Putting) is on.
function Gauge.start(isEnabled)
    enabled = isEnabled
    Loop.every(FRAMES_PER_UPDATE, "putt gauge", Gauge.update)
end

return Gauge
