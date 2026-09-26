-- Hole-in-one mode's on-screen tell: an orange pill in the golf HUD's top-right corner, styled like
-- the putt gauge's header. Pressing the toggle flashes "ACE ON" or "ACE OFF" for a moment; while the
-- mode stays on the pill says "ACE". The golf HUD is found as the game creates it, so the pill shows
-- with or without a club in hand. The widget helpers mirror gauge.lua's.
local Golf = require("golf")
local Loop = require("loop")

local Badge = {}

local HUD_CLASS = "/Game/Ride/UI/PlayerHUD/WG_PlayerHUD_Golf.WG_PlayerHUD_Golf_C"
local NAME = "GHP_AceBadge"
local FRAMES_PER_UPDATE = 3
local WIDTH, HEIGHT = 136, 44
local EDGE = { right = 40, top = 36 } -- from the screen's top-right corner, clear of the game's HUD
local FLASH_SECONDS = 2

local ORANGE = { R = 0.807, G = 0.347, B = 0.102, A = 1 }
local GREY = { R = 0.32, G = 0.34, B = 0.34, A = 1 }
local WHITE = { R = 0.982, G = 0.982, B = 0.982, A = 1 }
local SHADOW = { R = 0, G = 0, B = 0, A = 0.35 }

local VISIBLE_NO_HIT = 3 -- ESlateVisibility::HitTestInvisible
local COLLAPSED = 1
local HALIGN_RIGHT, VALIGN_TOP = 3, 1
local JUSTIFY_CENTER = 1
local ROUNDED_BOX = 4

local isOn = function() return false end
local huds = {}       -- golf HUDs, collected as the game creates them
local ui = nil        -- the built pill, for the HUD it lives in
local wasOn, changedAt = false, nil
local counter = 0
local statics = nil

local function valid(object) return object ~= nil and object:IsValid() end

local function construct(class, outer, name)
    counter = counter + 1
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. class), outer, FName(string.format("%s_%s_%d", NAME, name, counter)))
end

local function slate(color) return { SpecifiedColor = color, ColorUseRule = 0 } end

local function pillBrush(fill)
    return {
        ImageSize = { X = 32, Y = 32 },
        DrawAs = ROUNDED_BOX,
        TintColor = slate(fill),
        OutlineSettings = {
            CornerRadii = { X = 16, Y = 16, Z = 16, W = 16 },
            Color = slate(WHITE),
            Width = 3,
            RoundingType = 0,
        },
    }
end

local function place(canvas, widget, x, y, w, h)
    local slot = canvas:AddChildToCanvas(widget)
    slot:SetAutoSize(false)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
end

-- The live golf HUD: the held club's, else the newest one the game has made for a player.
local function currentHud()
    local controller = Golf.localController()
    local club = valid(controller) and valid(controller.Pawn) and Golf.heldClub(controller.Pawn) or nil
    if club ~= nil and valid(club.CachedGolfHUD) then return club.CachedGolfHUD end
    for i = #huds, 1, -1 do
        local hud = huds[i]
        if not valid(hud) then
            table.remove(huds, i)
        elseif valid(hud.WidgetTree) and valid(hud.WidgetTree.RootWidget) then
            return hud
        end
    end
    return nil
end

local function remember(hud)
    if valid(hud) and hud:GetFullName():find("Transient", 1, true) then huds[#huds + 1] = hud end
end

local function build(hud)
    if ui ~= nil and valid(ui.root) then ui.root:RemoveFromParent() end -- the pill moves, not copies
    local tree = hud.WidgetTree
    local root = tree.RootWidget
    for i = root:GetChildrenCount() - 1, 0, -1 do
        local child = root:GetChildAt(i)
        if valid(child) and child:GetFName():ToString():find("^" .. NAME) then child:RemoveFromParent() end
    end
    local template = hud.WG_GolfClubInfo.CurrentClubName
    local size = construct("SizeBox", tree, "Size")
    size:SetWidthOverride(WIDTH)
    size:SetHeightOverride(HEIGHT)
    local slot = root:AddChildToOverlay(size)
    slot:SetHorizontalAlignment(HALIGN_RIGHT)
    slot:SetVerticalAlignment(VALIGN_TOP)
    slot:SetPadding({ Left = 0, Top = EDGE.top, Right = EDGE.right, Bottom = 0 })
    local canvas = construct("CanvasPanel", tree, "Canvas")
    size:AddChild(canvas)
    local pill = construct("Image", tree, "Pill")
    pill:SetBrush(pillBrush(ORANGE))
    place(canvas, pill, 0, 0, WIDTH, HEIGHT)
    local text = construct("TextBlock", tree, "Text")
    local f = template.Font
    text:SetFont({ FontObject = f.FontObject, TypefaceFontName = f.TypefaceFontName, Size = 22, LetterSpacing = f.LetterSpacing })
    text:SetColorAndOpacity(slate(WHITE))
    text:SetJustification(JUSTIFY_CENTER)
    text:SetShadowOffset({ X = 1.5, Y = 1.5 })
    text:SetShadowColorAndOpacity(SHADOW)
    place(canvas, text, 0, 6, WIDTH, HEIGHT - 6)
    size:SetVisibility(COLLAPSED)
    ui = { hud = hud, root = size, pill = pill, text = text, shown = false, label = nil, fill = ORANGE }
end

-- What the pill says right now, and its colour; nil when it should be hidden.
local function look(on, now)
    local flashing = changedAt ~= nil and now - changedAt < FLASH_SECONDS
    if on then return flashing and "ACE ON" or "ACE", ORANGE end
    if flashing then return "ACE OFF", GREY end
    return nil
end

function Badge.update()
    local hud = currentHud()
    if hud == nil then return end
    local ok, now = pcall(function() return statics:GetRealTimeSeconds(hud) end)
    if not ok then now = os.time() end
    local on = isOn()
    if on ~= wasOn then wasOn, changedAt = on, now end
    local label, fill = look(on, now)
    if label == nil and (ui == nil or not ui.shown) then return end
    if ui == nil or not valid(ui.root) or ui.hud:GetAddress() ~= hud:GetAddress() then build(hud) end
    if label == nil then
        ui.shown = false
        ui.root:SetVisibility(COLLAPSED)
        return
    end
    if label ~= ui.label then
        ui.label = label
        ui.text:SetText(FText(label))
    end
    if fill ~= ui.fill then
        ui.fill = fill
        ui.pill:SetBrush(pillBrush(fill))
    end
    if not ui.shown then
        ui.shown = true
        ui.root:SetVisibility(VISIBLE_NO_HIT)
    end
end

-- aceOn: function returning whether hole-in-one mode is on.
function Badge.start(aceOn)
    isOn = aceOn
    statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    ExecuteInGameThread(function()
        LoadAsset(HUD_CLASS)
        NotifyOnNewObject(HUD_CLASS, remember)
    end)
    Loop.every(FRAMES_PER_UPDATE, "ace badge", Badge.update)
end

return Badge
